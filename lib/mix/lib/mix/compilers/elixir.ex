defmodule Mix.Compilers.Elixir do
  @moduledoc false

  @manifest_vsn :v7

  import Record

  defrecord :module, [:module, :kind, :sources, :beam, :binary]

  defrecord :source,
    source: nil,
    size: 0,
    compile_references: [],
    runtime_references: [],
    compile_dispatches: [],
    runtime_dispatches: [],
    external: [],
    warnings: []

  @doc """
  Compiles stale Elixir files.

  It expects a `manifest` file, the source directories, the destination
  directory, a flag to know if compilation is being forced or not, and a
  list of any additional compiler options.

  The `manifest` is written down with information including dependencies
  between modules, which helps it recompile only the modules that
  have changed at runtime.
  """
  def compile(manifest, srcs, dest, exts, force, opts) do
    # We fetch the time from before we read files so any future
    # change to files are still picked up by the compiler. This
    # timestamp is used when writing BEAM files and the manifest.
    timestamp = :calendar.universal_time()
    all_paths = MapSet.new(Mix.Utils.extract_files(srcs, exts))

    {all_modules, all_sources} = parse_manifest(manifest, dest)
    modified = Mix.Utils.last_modified(manifest)
    prev_paths = for source(source: source) <- all_sources, into: MapSet.new(), do: source

    removed =
      prev_paths
      |> MapSet.difference(all_paths)
      |> MapSet.to_list()

    changed =
      if force do
        # A config, path dependency or manifest has
        # changed, let's just compile everything
        MapSet.to_list(all_paths)
      else
        sources_stats = mtimes_and_sizes(all_sources)

        # Otherwise let's start with the new sources
        new_paths =
          all_paths
          |> MapSet.difference(prev_paths)
          |> MapSet.to_list()

        # Plus the sources that have changed in disk
        for source(source: source, external: external, size: size) <- all_sources,
            {last_mtime, last_size} = Map.fetch!(sources_stats, source),
            times = Enum.map(external, &(sources_stats |> Map.fetch!(&1) |> elem(0))),
            size != last_size or Mix.Utils.stale?([last_mtime | times], [modified]),
            into: new_paths,
            do: source
      end

    stale_local_deps = stale_local_deps(manifest, modified)

    {modules, changed} =
      update_stale_entries(all_modules, all_sources, removed ++ changed, stale_local_deps)

    stale = changed -- removed
    sources = update_stale_sources(all_sources, removed, changed)

    if opts[:all_warnings], do: show_warnings(sources)

    cond do
      stale != [] ->
        compile_manifest(manifest, exts, modules, sources, stale, dest, timestamp, opts)

      removed != [] ->
        write_manifest(manifest, modules, sources, dest, timestamp)
        {:ok, warning_diagnostics(sources)}

      true ->
        {:noop, warning_diagnostics(sources)}
    end
  end

  defp mtimes_and_sizes(sources) do
    Enum.reduce(sources, %{}, fn source(source: source, external: external), map ->
      Enum.reduce([source | external], map, fn file, map ->
        Map.put_new_lazy(map, file, fn -> Mix.Utils.last_modified_and_size(file) end)
      end)
    end)
  end

  @doc """
  Removes compiled files for the given `manifest`.
  """
  def clean(manifest, compile_path) do
    Enum.each(read_manifest(manifest, compile_path), fn
      module(beam: beam) -> File.rm(beam)
      _ -> :ok
    end)
  end

  @doc """
  Returns protocols and implementations for the given `manifest`.
  """
  def protocols_and_impls(manifest, compile_path) do
    for module(beam: beam, module: module, kind: kind) <- read_manifest(manifest, compile_path),
        match?(:protocol, kind) or match?({:impl, _}, kind),
        do: {module, kind, beam}
  end

  @doc """
  Reads the manifest.
  """
  def read_manifest(manifest, compile_path) do
    try do
      manifest |> File.read!() |> :erlang.binary_to_term()
    rescue
      _ -> []
    else
      [@manifest_vsn | data] -> expand_beam_paths(data, compile_path)
      _ -> []
    end
  end

  defp compile_manifest(manifest, exts, modules, sources, stale, dest, timestamp, opts) do
    Mix.Utils.compiling_n(length(stale), hd(exts))
    Mix.Project.ensure_structure()
    true = Code.prepend_path(dest)
    set_compiler_opts(opts)
    cwd = File.cwd!()

    extra =
      if opts[:verbose] do
        [each_file: &each_file/1]
      else
        []
      end

    # Starts a server responsible for keeping track which files
    # were compiled and the dependencies between them.
    {:ok, pid} = Agent.start_link(fn -> {modules, sources} end)
    long_compilation_threshold = opts[:long_compilation_threshold] || 10

    compile_opts = [
      each_module: &each_module(pid, cwd, &1, &2, &3),
      each_long_compilation: &each_long_compilation(&1, long_compilation_threshold),
      long_compilation_threshold: long_compilation_threshold,
      dest: dest
    ]

    try do
      Kernel.ParallelCompiler.compile(stale, compile_opts ++ extra)
    after
      Agent.stop(pid, :normal, :infinity)
    else
      {:ok, _, warnings} ->
        Agent.get(pid, fn {modules, sources} ->
          sources = apply_warnings(sources, warnings)
          write_manifest(manifest, modules, sources, dest, timestamp)
          {:ok, warning_diagnostics(sources)}
        end)

      {:error, errors, warnings} ->
        errors = Enum.map(errors, &diagnostic(&1, :error))

        warnings =
          Enum.map(warnings, &diagnostic(&1, :warning)) ++
            Agent.get(pid, fn {_, sources} -> warning_diagnostics(sources) end)

        {:error, warnings ++ errors}
    end
  end

  defp set_compiler_opts(opts) do
    opts
    |> Keyword.take(Code.available_compiler_options())
    |> Code.compiler_options()
  end

  defp each_module(pid, cwd, source, module, binary) do
    {compile_references, runtime_references} = Kernel.LexicalTracker.remote_references(module)

    compile_references =
      compile_references
      |> List.delete(module)
      |> Enum.reject(&match?("elixir_" <> _, Atom.to_string(&1)))

    runtime_references =
      runtime_references
      |> List.delete(module)

    {compile_dispatches, runtime_dispatches} = Kernel.LexicalTracker.remote_dispatches(module)

    compile_dispatches =
      compile_dispatches
      |> Enum.reject(&match?("elixir_" <> _, Atom.to_string(elem(&1, 0))))

    runtime_dispatches =
      runtime_dispatches
      |> Enum.to_list()

    kind = detect_kind(module)
    source = Path.relative_to(source, cwd)
    external = get_external_resources(module, cwd)

    Agent.cast(pid, fn {modules, sources} ->
      source_external =
        case List.keyfind(sources, source, source(:source)) do
          source(external: old_external) -> external ++ old_external
          nil -> external
        end

      module_sources =
        case List.keyfind(modules, module, module(:module)) do
          module(sources: old_sources) -> [source | List.delete(old_sources, source)]
          nil -> [source]
        end

      # They are calculated when writing the manifest
      new_module =
        module(
          module: module,
          kind: kind,
          sources: module_sources,
          beam: nil,
          binary: binary
        )

      new_source =
        source(
          source: source,
          size: :filelib.file_size(source),
          compile_references: compile_references,
          runtime_references: runtime_references,
          compile_dispatches: compile_dispatches,
          runtime_dispatches: runtime_dispatches,
          external: source_external,
          warnings: []
        )

      modules = List.keystore(modules, module, module(:module), new_module)
      sources = List.keystore(sources, source, source(:source), new_source)
      {modules, sources}
    end)
  end

  defp detect_kind(module) do
    protocol_metadata = Module.get_attribute(module, :protocol_impl)

    cond do
      is_list(protocol_metadata) and protocol_metadata[:protocol] ->
        {:impl, protocol_metadata[:protocol]}

      is_list(Module.get_attribute(module, :protocol)) ->
        :protocol

      true ->
        :module
    end
  end

  defp get_external_resources(module, cwd) do
    for file <- Module.get_attribute(module, :external_resource), do: Path.relative_to(file, cwd)
  end

  defp each_file(source) do
    Mix.shell().info("Compiled #{source}")
  end

  defp each_long_compilation(source, threshold) do
    Mix.shell().info("Compiling #{source} (it's taking more than #{threshold}s)")
  end

  ## Resolution

  defp update_stale_sources(sources, removed, changed) do
    # Remove delete sources
    sources = Enum.reduce(removed, sources, &List.keydelete(&2, &1, source(:source)))

    # Store empty sources for the changed ones as the compiler appends data
    sources =
      Enum.reduce(changed, sources, &List.keystore(&2, &1, source(:source), source(source: &1)))

    sources
  end

  # This function receives the manifest entries and some source
  # files that have changed. It then, recursively, figures out
  # all the files that changed (via the module dependencies) and
  # return the non-changed entries and the removed sources.
  defp update_stale_entries(modules, _sources, [], stale) when stale == %{} do
    {modules, []}
  end

  defp update_stale_entries(modules, sources, changed, stale) do
    changed = Enum.into(changed, %{}, &{&1, true})
    remove_stale_entries(modules, sources, stale, changed)
  end

  defp remove_stale_entries(modules, sources, old_stale, old_changed) do
    {rest, new_stale, new_changed} =
      Enum.reduce(modules, {[], old_stale, old_changed}, &remove_stale_entry(&1, &2, sources))

    if map_size(new_stale) > map_size(old_stale) or map_size(new_changed) > map_size(old_changed) do
      remove_stale_entries(rest, sources, new_stale, new_changed)
    else
      {rest, Map.keys(new_changed)}
    end
  end

  defp remove_stale_entry(entry, {rest, stale, changed}, sources_records) do
    module(module: module, beam: beam, sources: sources) = entry

    {compile_references, runtime_references} =
      Enum.reduce(sources, {[], []}, fn source, {compile_acc, runtime_acc} ->
        source(compile_references: compile_refs, runtime_references: runtime_refs) =
          List.keyfind(sources_records, source, source(:source))

        {compile_refs ++ compile_acc, runtime_refs ++ runtime_acc}
      end)

    cond do
      # If I changed in disk or have a compile time reference to
      # something stale, I need to be recompiled.
      has_any_key?(changed, sources) or has_any_key?(stale, compile_references) ->
        remove_and_purge(beam, module)
        changed = Enum.reduce(sources, changed, &Map.put(&2, &1, true))
        {rest, Map.put(stale, module, true), changed}

      # If I have a runtime references to something stale,
      # I am stale too.
      has_any_key?(stale, runtime_references) ->
        {[entry | rest], Map.put(stale, module, true), changed}

      # Otherwise, we don't store it anywhere
      true ->
        {[entry | rest], stale, changed}
    end
  end

  defp has_any_key?(map, enumerable) do
    Enum.any?(enumerable, &Map.has_key?(map, &1))
  end

  defp stale_local_deps(manifest, modified) do
    base = Path.basename(manifest)

    for %{scm: scm, opts: opts} = dep <- Mix.Dep.cached(),
        not scm.fetchable?,
        Mix.Utils.last_modified(Path.join(opts[:build], base)) > modified,
        path <- Mix.Dep.load_paths(dep),
        beam <- Path.wildcard(Path.join(path, "*.beam")),
        Mix.Utils.last_modified(beam) > modified,
        do: {beam |> Path.basename() |> Path.rootname() |> String.to_atom(), true},
        into: %{}
  end

  defp remove_and_purge(beam, module) do
    _ = File.rm(beam)
    _ = :code.purge(module)
    _ = :code.delete(module)
  end

  defp show_warnings(sources) do
    for source(source: source, warnings: warnings) <- sources do
      file = Path.absname(source)

      for {line, message} <- warnings do
        :elixir_errors.warn(line, file, message)
      end
    end
  end

  defp apply_warnings(sources, warnings) do
    warnings = Enum.group_by(warnings, &elem(&1, 0), &{elem(&1, 1), elem(&1, 2)})

    for source(source: source_path, warnings: source_warnings) = s <- sources do
      source(s, warnings: Map.get(warnings, Path.absname(source_path), source_warnings))
    end
  end

  defp warning_diagnostics(sources) do
    for source(source: source, warnings: warnings) <- sources,
        {line, message} <- warnings,
        do: diagnostic({Path.absname(source), line, message}, :warning)
  end

  defp diagnostic({file, line, message}, severity) do
    %Mix.Task.Compiler.Diagnostic{
      file: file,
      position: line,
      message: message,
      severity: severity,
      compiler_name: "Elixir"
    }
  end

  ## Manifest handling

  # Similar to read_manifest, but supports data migration.
  defp parse_manifest(manifest, compile_path) do
    try do
      manifest |> File.read!() |> :erlang.binary_to_term()
    rescue
      _ -> {[], []}
    else
      [@manifest_vsn | data] ->
        split_manifest(data, compile_path)

      [v | data] when v in [:v4, :v5, :v6] ->
        for module(beam: beam) <- data, do: File.rm(Path.join(compile_path, beam))
        {[], []}

      _ ->
        {[], []}
    end
  end

  defp split_manifest(data, compile_path) do
    Enum.reduce(data, {[], []}, fn
      module() = module, {modules, sources} ->
        {[expand_beam_path(module, compile_path) | modules], sources}

      source() = source, {modules, sources} ->
        {modules, [source | sources]}
    end)
  end

  defp expand_beam_path(module(beam: beam) = module, compile_path) do
    module(module, beam: Path.join(compile_path, beam))
  end

  defp expand_beam_paths(modules, ""), do: modules

  defp expand_beam_paths(modules, compile_path) do
    Enum.map(modules, fn
      module() = module ->
        expand_beam_path(module, compile_path)

      other ->
        other
    end)
  end

  defp write_manifest(manifest, [], [], _compile_path, _timestamp) do
    File.rm(manifest)
    :ok
  end

  defp write_manifest(manifest, modules, sources, compile_path, timestamp) do
    File.mkdir_p!(Path.dirname(manifest))

    modules =
      for module(binary: binary, module: module) = entry <- modules do
        beam = Atom.to_string(module) <> ".beam"

        if binary do
          beam_path = Path.join(compile_path, beam)
          File.write!(beam_path, binary)
          File.touch!(beam_path, timestamp)
        end

        module(entry, binary: nil, beam: beam)
      end

    manifest_data =
      [@manifest_vsn | modules ++ sources]
      |> :erlang.term_to_binary([:compressed])

    File.write!(manifest, manifest_data)
    File.touch!(manifest, timestamp)

    # Since Elixir is a dependency itself, we need to touch the lock
    # so the current Elixir version, used to compile the files above,
    # is properly stored.
    Mix.Dep.ElixirSCM.update()
  end
end
