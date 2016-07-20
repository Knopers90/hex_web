defmodule HexWeb.RegistryBuilder do
  @doc """
  Builds the ets registry file. Only one build process should run at a given
  time, but if a rebuild request comes in during building we need to rebuild
  immediately after again.
  """

  # TODO: installs ???
  # TODO: signing
  # TODO: remove skips

  import Ecto.Query, only: [from: 2]
  require HexWeb.Repo
  require Logger
  alias Ecto.Adapters.SQL
  alias HexWeb.Package
  alias HexWeb.Release
  alias HexWeb.Requirement
  alias HexWeb.Install

  @ets_table :hex_registry
  @version   4
  @wait_time 10_000

  def full_build do
    locked_build(&full/0)
  end

  def partial_build(action) do
    locked_build(fn -> partial(action) end)
  end

  defp locked_build(fun) do
    handle = HexWeb.Repo.insert!(HexWeb.Registry.build)

    try do
      HexWeb.Repo.transaction(fn ->
        SQL.query(HexWeb.Repo, "LOCK registries NOWAIT", [])
        run_or_skip(handle, fun)
      end)
    rescue
      error in [Postgrex.Error] ->
        stacktrace = System.stacktrace
        if error.postgres.code == :lock_not_available do
          :timer.sleep(@wait_time)
          run_or_skip(handle, fun)
        else
          reraise error, stacktrace
        end
    end
  end

  defp run_or_skip(handle, fun) do
    unless skip?(handle) do
      HexWeb.Registry.set_working(handle)
      |> HexWeb.Repo.update_all([])

      fun.()

      HexWeb.Registry.set_done(handle)
      |> HexWeb.Repo.update_all([])
    end
  end

  defp skip?(handle) do
    # Has someone already pushed data newer than we were planning push?
    latest_started = HexWeb.Registry.latest_started
                     |> HexWeb.Repo.one

    if latest_started && time_diff(latest_started, handle.inserted_at) > 0 do
      HexWeb.Registry.set_done(handle)
      |> HexWeb.Repo.update_all([])
      true
    else
      false
    end
  end

  defp full do
    log(:full, fn ->
      {packages, releases, installs} = tuples()

      ets = build_ets(packages, releases, installs)
      new = build_new(packages, releases)
      upload_files(ets, new)

      {_, _, packages} = new
      new_keys = Enum.map(packages, &"packages/#{elem(&1, 0)}") |> Enum.sort
      old_keys = HexWeb.Store.list(nil, :s3_bucket, "packages/") |> Enum.sort
      HexWeb.Store.delete_many(nil, :s3_bucket, old_keys -- new_keys, [])

      HexWeb.CDN.purge_key(:fastly_hexrepo, "registry")
    end)
  end

  defp partial(:v1) do
    log(:v1, fn ->
      {packages, releases, installs} = tuples()
      ets = build_ets(packages, releases, installs)
      upload_files(ets, nil)

      HexWeb.CDN.purge_key(:fastly_hexrepo, ["registry-index"])
    end)
  end

  defp partial({:single, package}) do
    log(:single, fn ->
      {packages, releases, installs} = tuples()

      ets = build_ets(packages, releases, installs)
      names = build_names(packages)
      versions = build_versions(packages)

      release_map = Enum.filter(releases, &match?({{^package, _}, _}, &1)) |> Map.new
      package_versions = Enum.find(packages, &match?({^package, _}, &1)) |> elem(1) |> hd
      package_object = build_package(package, package_versions, release_map)

      upload_files(ets, {names, versions, [{package, package_object}]})

      HexWeb.CDN.purge_key(:fastly_hexrepo, ["registry-index", "registry-package-#{package}"])
    end)
  end

  defp partial({:remove, package}) do
    log(:remove, fn ->
      {packages, releases, installs} = tuples()
      ets = build_ets(packages, releases, installs)
      names = build_names(packages)
      versions = build_versions(packages)

      upload_files(ets, {names, versions, []})
      HexWeb.Store.delete(nil, :s3_bucket, "packages/#{package}", [])

      HexWeb.CDN.purge_key(:fastly_hexrepo, ["registry-index", "registry-package-#{package}"])
    end)
  end

  defp tuples do
    installs       = installs()
    requirements   = requirements()
    releases       = releases()
    packages       = packages()
    package_tuples = package_tuples(packages, releases)
    release_tuples = release_tuples(packages, releases, requirements)

    {package_tuples, release_tuples, installs}
  end

  defp log(type, fun) do
    try do
      {time, _} = :timer.tc(fun)
      Logger.warn "REGISTRY_BUILDER_COMPLETED #{type} (#{div time, 1000}ms)"
    catch
      exception ->
        stacktrace = System.stacktrace
        Logger.error "REGISTRY_BUILDER_FAILED #{type}"
        reraise exception, stacktrace
    end
  end

  defp build_ets(packages, releases, installs) do
    file = Path.join("tmp", "registry-#{:erlang.unique_integer([:positive])}.ets")

    tid = :ets.new(@ets_table, [:public])
    :ets.insert(tid, {:"$$version$$", @version})
    :ets.insert(tid, {:"$$installs2$$", installs})
    :ets.insert(tid, packages)
    :ets.insert(tid, releases)
    :ok = :ets.tab2file(tid, String.to_char_list(file))
    :ets.delete(tid)

    contents = File.read!(file) |> :zlib.gzip
    {contents, try_sign(contents)}
  end

  defp try_sign(contents) do
    if key = Application.get_env(:hex_web, :signing_key) do
      HexWeb.Utils.sign(contents, key)
    end
  end

  defp build_new(packages, releases) do
    {build_names(packages),
     build_versions(packages),
     build_packages(packages, releases)}
  end

  def build_names(packages) do
    packages = Enum.map(packages, fn {name, _versions} -> %{name: name} end)
    %{packages: packages}
    |> :hex_pb_names.encode_msg(:Names)
    |> :zlib.gzip
  end

  def build_versions(packages) do
    packages = Enum.map(packages, fn {name, [versions]} -> %{name: name, versions: versions} end)
    %{packages: packages}
    |> :hex_pb_versions.encode_msg(:Versions)
    |> :zlib.gzip
  end

  def build_packages(packages, releases) do
    release_map = Map.new(releases)

    Enum.map(packages, fn {name, [versions]} ->
      contents = build_package(name, versions, release_map)
      {name, contents}
    end)
  end

  defp build_package(name, versions, release_map) do
    releases =
      Enum.map(versions, fn version ->
        [deps, checksum, _tools] = release_map[{name, version}]
        deps =
          Enum.map(deps, fn [dep, req, opt, app] ->
            map = %{package: dep, requirement: req}
            map = if opt, do: Map.put(map, :optional, true), else: map
            map = if app != dep, do: Map.put(map, :app, app), else: map
            map
          end)

        checksum = checksum |> Base.decode16!
        %{version: version, checksum: checksum, dependencies: deps}
      end)

    %{releases: releases}
    |> :hex_pb_package.encode_msg(:Package)
    |> :zlib.gzip
  end

  defp upload_files(v1, v2) do
    objects = v2_objects(v2) ++ v1_objects(v1)
    HexWeb.Store.put_many(nil, :s3_bucket, objects, [])
  end

  defp v1_objects(nil), do: []
  defp v1_objects({ets, signature}) do
    meta = [{"surrogate-key", "registry registry-index"}]
    index_meta = if signature, do: [{"signature", signature}|meta], else: meta
    opts = [acl: :public_read, cache_control: "public, max-age=600", meta: meta]
    index_opts = Keyword.put(opts, :meta, index_meta)

    ets_object = {"registry.ets.gz", ets, index_opts}

    if signature do
      signature_object = {"registry.ets.gz.signed", signature, opts}
      [ets_object, signature_object]
    else
      [ets_object]
    end
  end

  defp v2_objects(nil), do: []
  defp v2_objects({names, versions, packages}) do
    meta = [{"surrogate-key", "registry registry-index"}]
    opts = [acl: :public_read, cache_control: "public, max-age=600", meta: meta]
    index_opts = Keyword.put(opts, :meta, meta)

    names_object = {"names", names, index_opts}
    versions_object = {"versions", versions, index_opts}

    package_objects = Enum.map(packages, fn {name, contents} ->
      opts = Keyword.put(opts, :meta, [{"surrogate-key", "registry registry-package-#{name}"}])
      {"packages/#{name}", contents, opts}
    end)

    package_objects ++ [names_object, versions_object]
  end

  defp package_tuples(packages, releases) do
    Enum.reduce(releases, %{}, fn {_, vsn, pkg_id, _, _}, map ->
      case Map.fetch(packages, pkg_id) do
        {:ok, package} -> Map.update(map, package, [vsn], &[vsn|&1])
        :error -> map
      end
    end)
    |> sort_package_tuples
  end

  defp sort_package_tuples(tuples) do
    Enum.map(tuples, fn {name, versions} ->
      versions =
        Enum.sort(versions, &(Version.compare(&1, &2) == :lt))
        |> Enum.map(&to_string/1)

      {name, [versions]}
    end)
    |> Enum.sort
  end

  defp release_tuples(packages, releases, requirements) do
    Enum.flat_map(releases, fn {id, version, pkg_id, checksum, tools} ->
      case Map.fetch(packages, pkg_id) do
        {:ok, package} ->
          deps = deps_list(requirements[id] || [], packages)
          [{{package, to_string(version)}, [deps, checksum, tools]}]
        :error ->
          []
      end
    end)
  end

  defp deps_list(requirements, packages) do
    Enum.flat_map(requirements, fn {dep_id, app, req, opt} ->
      case Map.fetch(packages, dep_id) do
        {:ok, dep} -> [[dep, req, opt, app]]
        :error -> []
      end
    end)
    |> Enum.sort
  end

  defp packages do
    from(p in Package, select: {p.id, p.name})
    |> HexWeb.Repo.all
    |> Enum.into(%{})
  end

  defp releases do
    from(r in Release, select: {r.id, r.version, r.package_id, r.checksum, fragment("?->'build_tools'", r.meta)})
    |> HexWeb.Repo.all
  end

  defp requirements do
    reqs =
      from(r in Requirement,
           select: {r.release_id, r.dependency_id, r.app, r.requirement, r.optional})
      |> HexWeb.Repo.all

    Enum.reduce(reqs, %{}, fn {rel_id, dep_id, app, req, opt}, map ->
      tuple = {dep_id, app, req, opt}
      Map.update(map, rel_id, [tuple], &[tuple|&1])
    end)
  end

  defp installs do
    Install.all
    |> HexWeb.Repo.all
    |> Enum.map(&{&1.hex, &1.elixirs})
  end

  defp time_diff(time1, time2) do
    time1 = Ecto.DateTime.to_erl(time1) |> :calendar.datetime_to_gregorian_seconds
    time2 = Ecto.DateTime.to_erl(time2) |> :calendar.datetime_to_gregorian_seconds
    time1 - time2
  end
end
