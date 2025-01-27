defmodule Gettext.Compiler do
  @moduledoc false

  alias Gettext.{
    PO,
    PO.Translation,
    PO.PluralTranslation
  }

  require Logger

  @default_priv "priv/gettext"
  @default_domain "default"
  @po_wildcard "*/LC_MESSAGES/*.po"

  @doc false
  defmacro __before_compile__(env) do
    opts = Module.get_attribute(env.module, :gettext_opts)
    otp_app = Keyword.fetch!(opts, :otp_app)
    priv = Keyword.get(opts, :priv, @default_priv)
    translations_dir = Application.app_dir(otp_app, priv)
    external_file = String.replace(Path.join(".compile", priv), "/", "_")
    known_po_files = known_po_files(translations_dir, opts)
    known_locales = Enum.map(known_po_files, & &1[:locale]) |> Enum.uniq()

    default_locale =
      opts[:default_locale] || quote(do: Application.fetch_env!(:gettext, :default_locale))

    default_domain = opts[:default_domain] || @default_domain

    interpolation = opts[:interpolation] || Gettext.Interpolation.Default

    quote do
      @behaviour Gettext.Backend

      # Info about the Gettext backend.
      @doc false
      def __gettext__(:priv), do: unquote(priv)
      def __gettext__(:otp_app), do: unquote(otp_app)
      def __gettext__(:known_locales), do: unquote(known_locales)
      def __gettext__(:default_locale), do: unquote(default_locale)
      def __gettext__(:default_domain), do: unquote(default_domain)
      def __gettext__(:interpolation), do: unquote(interpolation)

      # The manifest lives in the root of the priv
      # directory that contains .po/.pot files.
      @external_resource unquote(Application.app_dir(otp_app, external_file))

      if Gettext.Extractor.extracting?() do
        Gettext.ExtractorAgent.add_backend(__MODULE__)
      end

      unquote(macros())

      # These are the two functions we generated inside the backend.
      def lgettext(locale, domain, msgctxt \\ nil, msgid, bindings)
      def lngettext(locale, domain, msgctxt \\ nil, msgid, msgid_plural, n, bindings)

      unquote(compile_po_files(env, known_po_files, opts))

      # Catch-all clauses.
      def lgettext(locale, domain, msgctxt, msgid, bindings),
        do: handle_missing_translation(locale, domain, msgctxt, msgid, bindings)

      def lngettext(locale, domain, msgctxt, msgid, msgid_plural, n, bindings),
        do:
          handle_missing_plural_translation(
            locale,
            domain,
            msgctxt,
            msgid,
            msgid_plural,
            n,
            bindings
          )
    end
  end

  defp macros() do
    quote unquote: false do
      defmacro dpgettext_noop(domain, msgctxt, msgid) do
        domain = Gettext.Compiler.expand_to_binary(domain, "domain", __MODULE__, __CALLER__)
        msgid = Gettext.Compiler.expand_to_binary(msgid, "msgid", __MODULE__, __CALLER__)
        msgctxt = Gettext.Compiler.expand_to_binary(msgctxt, "msgctxt", __MODULE__, __CALLER__)

        if Gettext.Extractor.extracting?() do
          Gettext.Extractor.extract(
            __CALLER__,
            __MODULE__,
            domain,
            msgctxt,
            msgid,
            Gettext.Compiler.get_and_flush_extracted_comments()
          )
        end

        msgid
      end

      defmacro dgettext_noop(domain, msgid) do
        quote do
          unquote(__MODULE__).dpgettext_noop(unquote(domain), nil, unquote(msgid))
        end
      end

      defmacro gettext_noop(msgid) do
        domain = __gettext__(:default_domain)

        quote do
          unquote(__MODULE__).dpgettext_noop(unquote(domain), nil, unquote(msgid))
        end
      end

      defmacro pgettext_noop(msgid, context) do
        domain = __gettext__(:default_domain)

        quote do
          unquote(__MODULE__).dpgettext_noop(unquote(domain), unquote(context), unquote(msgid))
        end
      end

      defmacro dpngettext_noop(domain, msgctxt, msgid, msgid_plural) do
        domain = Gettext.Compiler.expand_to_binary(domain, "domain", __MODULE__, __CALLER__)
        msgid = Gettext.Compiler.expand_to_binary(msgid, "msgid", __MODULE__, __CALLER__)
        msgctxt = Gettext.Compiler.expand_to_binary(msgctxt, "msgctxt", __MODULE__, __CALLER__)

        msgid_plural =
          Gettext.Compiler.expand_to_binary(msgid_plural, "msgid_plural", __MODULE__, __CALLER__)

        if Gettext.Extractor.extracting?() do
          Gettext.Extractor.extract(
            __CALLER__,
            __MODULE__,
            domain,
            msgctxt,
            {msgid, msgid_plural},
            Gettext.Compiler.get_and_flush_extracted_comments()
          )
        end

        {msgid, msgid_plural}
      end

      defmacro dngettext_noop(domain, msgid, msgid_plural) do
        quote do
          unquote(__MODULE__).dpngettext_noop(
            unquote(domain),
            nil,
            unquote(msgid),
            unquote(msgid_plural)
          )
        end
      end

      defmacro pngettext_noop(msgctxt, msgid, msgid_plural) do
        domain = __gettext__(:default_domain)

        quote do
          unquote(__MODULE__).dpngettext_noop(
            unquote(domain),
            unquote(msgctxt),
            unquote(msgid),
            unquote(msgid_plural)
          )
        end
      end

      defmacro ngettext_noop(msgid, msgid_plural) do
        domain = __gettext__(:default_domain)

        quote do
          unquote(__MODULE__).dpngettext_noop(
            unquote(domain),
            nil,
            unquote(msgid),
            unquote(msgid_plural)
          )
        end
      end

      defmacro dpgettext(domain, msgctxt, msgid, bindings \\ Macro.escape(%{})) do
        quote do
          msgid =
            unquote(__MODULE__).dpgettext_noop(unquote(domain), unquote(msgctxt), unquote(msgid))

          Gettext.dpgettext(
            unquote(__MODULE__),
            unquote(domain),
            unquote(msgctxt),
            msgid,
            unquote(bindings)
          )
        end
      end

      defmacro dgettext(domain, msgid, bindings \\ Macro.escape(%{})) do
        quote do
          unquote(__MODULE__).dpgettext(unquote(domain), nil, unquote(msgid), unquote(bindings))
        end
      end

      defmacro pgettext(msgctxt, msgid, bindings \\ Macro.escape(%{})) do
        domain = __gettext__(:default_domain)

        quote do
          unquote(__MODULE__).dpgettext(
            unquote(domain),
            unquote(msgctxt),
            unquote(msgid),
            unquote(bindings)
          )
        end
      end

      defmacro gettext(msgid, bindings \\ Macro.escape(%{})) do
        domain = __gettext__(:default_domain)

        quote do
          unquote(__MODULE__).dpgettext(unquote(domain), nil, unquote(msgid), unquote(bindings))
        end
      end

      defmacro dpngettext(domain, msgctxt, msgid, msgid_plural, n, bindings \\ Macro.escape(%{})) do
        quote do
          {msgid, msgid_plural} =
            unquote(__MODULE__).dpngettext_noop(
              unquote(domain),
              unquote(msgctxt),
              unquote(msgid),
              unquote(msgid_plural)
            )

          Gettext.dpngettext(
            unquote(__MODULE__),
            unquote(domain),
            unquote(msgctxt),
            msgid,
            msgid_plural,
            unquote(n),
            unquote(bindings)
          )
        end
      end

      defmacro dngettext(domain, msgid, msgid_plural, n, bindings \\ Macro.escape(%{})) do
        quote do
          unquote(__MODULE__).dpngettext(
            unquote(domain),
            nil,
            unquote(msgid),
            unquote(msgid_plural),
            unquote(n),
            unquote(bindings)
          )
        end
      end

      defmacro ngettext(msgid, msgid_plural, n, bindings \\ Macro.escape(%{})) do
        domain = __gettext__(:default_domain)

        quote do
          unquote(__MODULE__).dpngettext(
            unquote(domain),
            nil,
            unquote(msgid),
            unquote(msgid_plural),
            unquote(n),
            unquote(bindings)
          )
        end
      end

      defmacro pngettext(msgctxt, msgid, msgid_plural, n, bindings \\ Macro.escape(%{})) do
        domain = __gettext__(:default_domain)

        quote do
          unquote(__MODULE__).dpngettext(
            unquote(domain),
            unquote(msgctxt),
            unquote(msgid),
            unquote(msgid_plural),
            unquote(n),
            unquote(bindings)
          )
        end
      end

      defmacro gettext_comment(comment) do
        comment = Gettext.Compiler.expand_to_binary(comment, "comment", __MODULE__, __CALLER__)
        Gettext.Compiler.append_extracted_comment(comment)
        :ok
      end
    end
  end

  @doc """
  Expands the given `msgid` in the given `env`, raising if it doesn't expand to
  a binary.
  """
  @spec expand_to_binary(binary, binary, module, Macro.Env.t()) :: binary | no_return
  def expand_to_binary(term, what, gettext_module, env)
      when what in ~w(domain msgctxt msgid msgid_plural comment) do
    raiser = fn term ->
      raise ArgumentError, """
      Gettext macros expect translation keys (msgid and msgid_plural),
      domains, and comments to expand to strings at compile-time, but the given #{what}
      doesn't. This is what the macro received:

      #{inspect(term)}

      Dynamic translations should be avoided as they limit Gettext's
      ability to extract translations from your source code. If you are
      sure you need dynamic lookup, you can use the functions in the Gettext
      module:

          string = "hello world"
          Gettext.gettext(#{inspect(gettext_module)}, string)
      """
    end

    # We support nil too in order to fall back to a nil context and always use the *p
    # variants of the Gettext macros.
    case Macro.expand(term, env) do
      term when is_binary(term) or is_nil(term) ->
        term

      {:<<>>, _, pieces} = term ->
        if Enum.all?(pieces, &is_binary/1), do: Enum.join(pieces), else: raiser.(term)

      other ->
        raiser.(other)
    end
  end

  @doc """
  Appends the given comment to the list of extracted comments in the process dictionary.
  """
  @spec append_extracted_comment(binary) :: :ok
  def append_extracted_comment(comment) do
    existing = Process.get(:gettext_comments, [])
    Process.put(:gettext_comments, ["#. " <> comment | existing])
    :ok
  end

  @doc """
  Returns all extracted comments in the process dictionary and clears them from the process
  dictionary.
  """
  @spec get_and_flush_extracted_comments() :: [binary]
  def get_and_flush_extracted_comments() do
    Enum.reverse(Process.delete(:gettext_comments) || [])
  end

  @doc """
  Logs a warning via `Logger.error/1` if `domain` contains slashes.

  This function is called by `lgettext` and `lngettext`. It could make sense to
  make this function raise an error since slashes in domains are not supported,
  but we decided not to do so and to only emit a warning since the expected
  behaviour for Gettext functions/macros when the domain or translation is not
  known is to return the original string (msgid) and raising here would break
  that contract.
  """
  @spec warn_if_domain_contains_slashes(binary) :: :ok
  def warn_if_domain_contains_slashes(domain) do
    if String.contains?(domain, "/") do
      _ = Logger.error(fn -> ["Slashes in domains are not supported: ", inspect(domain)] end)
    end

    :ok
  end

  # Compiles all the `.po` files in the given directory (`dir`) into `lgettext/4`
  # and `lngettext/6` function clauses.
  defp compile_po_files(env, known_po_files, opts) do
    plural_mod =
      Keyword.get(opts, :plural_forms) ||
        Application.get_env(:gettext, :plural_forms, Gettext.Plural)

    opts =
      if opts[:one_module_per_locale] do
        IO.warn(
          ":one_module_per_locale is deprecated, please use split_module_by: [:locale] instead"
        )

        Keyword.put_new(opts, :split_module_by, [:locale])
      else
        opts
      end

    case List.wrap(opts[:split_module_by]) do
      [] ->
        Enum.map(
          known_po_files,
          &compile_unified_po_file(env, &1, plural_mod, opts[:interpolation])
        )

      split ->
        grouped = Enum.group_by(known_po_files, &split_module_name(env, &1, split))

        case Keyword.get(opts, :split_module_compilation, :parallel) do
          :serial ->
            Enum.map(grouped, fn {module, files} ->
              compile_split_po_files(env, module, files, plural_mod, opts[:interpolation])
            end)

          :parallel ->
            grouped
            |> Enum.map(fn {module, files} ->
              Kernel.ParallelCompiler.async(fn ->
                compile_split_po_files(env, module, files, plural_mod, opts[:interpolation])
              end)
            end)
            |> Enum.map(fn task ->
              Task.await(task, :infinity)
            end)
        end
    end
  end

  defp split_module_name(env, po_file, split) do
    String.to_atom(
      "#{env.module}.T" <>
        if(:locale in split, do: "_" <> po_file.locale, else: "") <>
        if(:domain in split, do: "_" <> po_file.domain, else: "")
    )
  end

  defp compile_unified_po_file(env, po_file, plural_mod, interpolation_module) do
    {locale, domain, singular_fun, plural_fun, quoted} =
      compile_po_file(:defp, po_file, env, plural_mod, interpolation_module)

    quote do
      unquote(quoted)

      def lgettext(unquote(locale), unquote(domain), msgctxt, msgid, bindings) do
        unquote(singular_fun)(msgctxt, msgid, bindings)
      end

      def lngettext(unquote(locale), unquote(domain), msgctxt, msgid, msgid_plural, n, bindings) do
        unquote(plural_fun)(msgctxt, msgid, msgid_plural, n, bindings)
      end
    end
  end

  defp compile_split_po_files(env, module, files, plural_mod, interpolation_module) do
    {current, split} =
      Enum.reduce(
        files,
        {[], []},
        &compile_split_po_file(env, module, plural_mod, &1, interpolation_module, &2)
      )

    create_split_module(env, module, split)
    current
  end

  defp compile_split_po_file(env, module, plural_mod, po_file, interpolation_module, {acc1, acc2}) do
    {locale, domain, singular_fun, plural_fun, split_module_quoted} =
      compile_po_file(:def, po_file, env, plural_mod, interpolation_module)

    current_module_quoted =
      quote do
        def lgettext(unquote(locale), unquote(domain), msgctxt, msgid, bindings) do
          unquote(module).unquote(singular_fun)(msgctxt, msgid, bindings)
        end

        def lngettext(unquote(locale), unquote(domain), msgctxt, msgid, msgid_plural, n, bindings) do
          unquote(module).unquote(plural_fun)(msgctxt, msgid, msgid_plural, n, bindings)
        end
      end

    {[current_module_quoted | acc1], [split_module_quoted | acc2]}
  end

  defp create_split_module(env, module, translations) do
    exprs = [quote(do: @moduledoc(false)) | translations]
    Module.create(module, block(exprs), env)
    :ok
  end

  # Compiles a .po file into a list of lgettext/5 (for translations) and
  # lngettext/7 (for plural translations) clauses.
  defp compile_po_file(kind, po_file, env, plural_mod, interpolation_module) do
    %{locale: locale, domain: domain, path: path} = po_file
    %PO{translations: translations, file: file} = PO.parse_file!(path)

    singular_fun = :"#{locale}_#{domain}_lgettext"
    plural_fun = :"#{locale}_#{domain}_lngettext"

    mapper =
      &compile_translation(
        kind,
        locale,
        &1,
        singular_fun,
        plural_fun,
        file,
        plural_mod,
        interpolation_module
      )

    translations = block(Enum.map(translations, mapper))

    quoted =
      quote do
        unquote(translations)

        Kernel.unquote(kind)(unquote(singular_fun)(msgctxt, msgid, bindings)) do
          unquote(env.module).handle_missing_translation(
            unquote(locale),
            unquote(domain),
            msgctxt,
            msgid,
            bindings
          )
        end

        Kernel.unquote(kind)(unquote(plural_fun)(msgctxt, msgid, msgid_plural, n, bindings)) do
          unquote(env.module).handle_missing_plural_translation(
            unquote(locale),
            unquote(domain),
            msgctxt,
            msgid,
            msgid_plural,
            n,
            bindings
          )
        end
      end

    {locale, domain, singular_fun, plural_fun, quoted}
  end

  defp locale_and_domain_from_path(path) do
    [file, "LC_MESSAGES", locale | _rest] = path |> Path.split() |> Enum.reverse()
    domain = Path.rootname(file, ".po")
    {locale, domain}
  end

  defp compile_translation(
         kind,
         _locale,
         %Translation{} = t,
         singular_fun,
         _plural_fun,
         _file,
         _plural_mod,
         interpolation_module
       ) do
    msgid = IO.iodata_to_binary(t.msgid)
    msgstr = IO.iodata_to_binary(t.msgstr)
    msgctxt = t.msgctxt && IO.iodata_to_binary(t.msgctxt)

    case msgstr do
      # Only actually generate this function clause if the msgstr is not empty.
      # If it is empty, it will trigger the missing translation case.
      "" ->
        nil

      _ ->
        quote do
          Kernel.unquote(kind)(
            unquote(singular_fun)(unquote(msgctxt), unquote(msgid), bindings)
          ) do
            require unquote(interpolation_module)

            unquote(interpolation_module).compile_interpolate(
              :translation,
              unquote(msgstr),
              bindings
            )
          end
        end
    end
  end

  defp compile_translation(
         kind,
         locale,
         %PluralTranslation{} = t,
         _singular_fun,
         plural_fun,
         file,
         plural_mod,
         interpolation_module
       ) do
    warn_if_missing_plural_forms(locale, plural_mod, t, file)

    msgid = IO.iodata_to_binary(t.msgid)
    msgid_plural = IO.iodata_to_binary(t.msgid_plural)
    msgstr = Enum.map(t.msgstr, fn {form, str} -> {form, IO.iodata_to_binary(str)} end)
    msgctxt = t.msgctxt && IO.iodata_to_binary(t.msgctxt)

    # If any of the msgstrs is empty, then we skip the generation of this
    # function clause. The reason we do this is the same as for the
    # `%Translation{}` clause.
    unless Enum.any?(msgstr, &match?({_form, ""}, &1)) do
      # We use flat_map here because clauses can only be defined in blocks,
      # so when quoted they are a list.
      clauses =
        Enum.flat_map(msgstr, fn {form, str} ->
          quote do
            unquote(form) ->
              require unquote(interpolation_module)

              unquote(interpolation_module).compile_interpolate(
                :plural_translation,
                unquote(str),
                var!(bindings)
              )
          end
        end)

      error_clause =
        quote do
          form ->
            raise Gettext.PluralFormError,
              form: form,
              locale: unquote(locale),
              file: unquote(file),
              line: unquote(t.po_source_line)
        end

      quote generated: true do
        Kernel.unquote(kind)(
          unquote(plural_fun)(
            unquote(msgctxt),
            unquote(msgid),
            unquote(msgid_plural),
            n,
            bindings
          )
        ) do
          plural_form = unquote(plural_mod).plural(unquote(locale), n)
          var!(bindings) = Map.put(bindings, :count, n)

          case plural_form, do: unquote(clauses ++ error_clause)
        end
      end
    end
  end

  defp warn_if_missing_plural_forms(locale, plural_mod, translation, file) do
    Enum.each(0..(plural_mod.nplurals(locale) - 1), fn form ->
      unless Map.has_key?(translation.msgstr, form) do
        _ =
          Logger.error([
            "#{file}:#{translation.po_source_line}: translation is missing plural form ",
            Integer.to_string(form),
            " which is required by the locale ",
            inspect(locale)
          ])
      end
    end)
  end

  defp block(contents) when is_list(contents) do
    {:__block__, [], contents}
  end

  # Returns all the PO files in `translations_dir` (under "canonical" paths,
  # that is, `locale/LC_MESSAGES/domain.po`).
  defp po_files_in_dir(dir) do
    dir
    |> Path.join(@po_wildcard)
    |> Path.wildcard()
  end

  # Returns the known the PO files in `translations_dir` with their locale and domain
  # If allowed_locales is configured, it removes all the PO files that do not belong
  # to those locales
  defp known_po_files(translations_dir, opts) do
    case File.ls(translations_dir) do
      {:ok, _} ->
        translations_dir
        |> po_files_in_dir()
        |> Enum.map(fn path ->
          {locale, domain} = locale_and_domain_from_path(path)
          %{locale: locale, path: path, domain: domain}
        end)
        |> maybe_restrict_locales(opts[:allowed_locales])

      {:error, :enoent} ->
        []

      {:error, reason} ->
        raise File.Error, reason: reason, action: "list directory", path: translations_dir
    end
  end

  defp maybe_restrict_locales(po_files, nil) do
    po_files
  end

  defp maybe_restrict_locales(po_files, allowed_locales) when is_list(allowed_locales) do
    allowed_locales = MapSet.new(Enum.map(allowed_locales, &to_string/1))
    Enum.filter(po_files, &MapSet.member?(allowed_locales, &1[:locale]))
  end
end
