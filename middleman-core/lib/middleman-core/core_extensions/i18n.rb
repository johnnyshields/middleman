class Middleman::CoreExtensions::Internationalization < ::Middleman::Extension
  option :no_fallbacks, false, 'Disable I18n fallbacks'
  option :langs, nil, 'List of langs, will autodiscover by default'
  option :lang_map, {}, 'Language shortname map'
  option :path, '/:locale/', 'URL prefix path'
  option :templates_dir, 'localizable', 'Location of templates to be localized'
  option :mount_at_root, nil, 'Mount a specific language at the root of the site'
  option :data, 'locales', 'The directory holding your locale configurations'

  # Exposes `langs` to templates
  expose_to_template :langs

  self.resource_list_manipulator_priority = 70
  attr_reader :maps

  def initialize(*)
    super

    require 'i18n'

    # Don't fail on invalid locale, that's not what our current
    # users expect.
    ::I18n.enforce_available_locales = false

    # This is for making the tests work - since the tests
    # don't completely reload middleman, I18n.load_path can get
    # polluted with paths from other test app directories that don't
    # exist anymore.
    app.after_configuration_eval do
      ::I18n.load_path.delete_if { |path| path =~ %r{tmp/aruba} }
      ::I18n.reload!
    end if ENV['TEST']
  end

  def after_configuration
    # See https://github.com/svenfuchs/i18n/wiki/Fallbacks
    unless options[:no_fallbacks]
      require 'i18n/backend/fallbacks'
      ::I18n::Backend::Simple.send(:include, ::I18n::Backend::Fallbacks)
    end

    locales_file_path = options[:data]

    # Tell the file watcher to observe the :data_dir
    app.files.watch :locales,
                    path: File.join(app.root, locales_file_path),
                    only: /.*(rb|yml|yaml)$/

    # Setup data files before anything else so they are available when
    # parsing config.rb
    app.files.on_change(:locales, &method(:on_file_changed))

    @maps = {}
    @mount_at_root = options[:mount_at_root].nil? ? langs.first : options[:mount_at_root]

    configure_i18n

    logger.info "== Locales: #{langs.join(', ')} (Default #{@mount_at_root})"
  end

  helpers do
    def t(*args)
      ::I18n.t(*args)
    end

    def url_for(path_or_resource, options={})
      locale = options.delete(:locale) || ::I18n.locale

      opts = options.dup

      should_relativize = opts.key?(:relative) ? opts[:relative] : config[:relative_links]

      opts[:relative] = false

      href = super(path_or_resource, opts)

      final_path = if result = extensions[:i18n].localized_path(href, locale)
        result
      else
        # Should we log the missing file?
        href
      end

      opts[:relative] = should_relativize

      begin
        super(final_path, opts)
      rescue RuntimeError
        super(path_or_resource, options)
      end
    end

    def locate_partial(partial_name, try_static=false)
      locals_dir = extensions[:i18n].options[:templates_dir]

      # Try /localizable
      partials_path = File.join(locals_dir, partial_name)

      lang_suffix = ::I18n.locale

      extname = File.extname(partial_name)
      maybe_static = extname.length > 0
      suffixed_partial_name = if maybe_static
        partial_name.sub(extname, ".#{lang_suffix}#{extname}")
      else
        "#{partial_name}.#{lang_suffix}"
      end

      if lang_suffix
        super(suffixed_partial_name, maybe_static) ||
          super(File.join(locals_dir, suffixed_partial_name), maybe_static) ||
          super(partials_path, try_static) ||
          super
      else
        super(partials_path, try_static) ||
          super
      end
    end

    # Access localized path for `page_id`
    def locale_path(page_id, locale=I18n.locale)
      page_id = page_id.to_s
      maps = extensions[:i18n].maps

      path = maps[page_id].try(:[], locale)
      raise 'Path not found' unless path

      '/' + path
    end

    # Path to the same page in another locale
    def switch_locale_path(locale=other_locale)
      raise ArgumentError, 'No other locale to switch to' unless locale
      locale_path(current_page.locals[:page_id], locale)
    end

    def other_locale
      other_locales[0]
    end

    def other_locales
      extensions[:i18n].langs - [I18n.locale]
    end
  end

  Contract ArrayOf[Symbol]
  def langs
    @langs ||= known_languages
  end

  # Update the main sitemap resource list
  # @return Array<Middleman::Sitemap::Resource>
  Contract ResourceList => ResourceList
  def manipulate_resource_list(resources)
    new_resources = []

    file_extension_resources = resources.select do |resource|
      parse_locale_extension(resource.path)
    end

    localizable_folder_resources = resources.select do |resource|
      !file_extension_resources.include?(resource) && File.fnmatch?(File.join(options[:templates_dir], '**'), resource.path)
    end

    # If it's a "localizable template"
    localizable_folder_resources.each do |resource|
      page_id = File.basename(resource.path, File.extname(resource.path))
      langs.each do |lang|
        # Remove folder name
        path = resource.path.sub(options[:templates_dir], '')
        new_resources << build_resource(path, resource.path, page_id, lang)
      end

      resource.ignore!

      # This is for backwards compatibility with the old provides_metadata-based code
      # that used to be in this extension, but I don't know how much sense it makes.
      # next if resource.options[:lang]

      # $stderr.puts "Defaulting #{resource.path} to #{@mount_at_root}"
      # resource.add_metadata options: { lang: @mount_at_root }, locals: { lang: @mount_at_root }
    end

    # If it uses file extension localization
    file_extension_resources.each do |resource|
      result = parse_locale_extension(resource.path)
      ext_lang, path, page_id = result
      new_resources << build_resource(path, resource.path, page_id, ext_lang)

      resource.ignore!
    end

    @lookup = new_resources.each_with_object({}) do |desc, sum|
      abs_path = desc.source_path.sub(options[:templates_dir], '')
      sum[abs_path] ||= {}
      sum[abs_path][desc.lang] = '/' + desc.path
    end

    resources + new_resources.map { |r| r.to_resource(app) }
  end

  def localized_path(path, lang)
    lookup_path = path.dup
    lookup_path << app.config[:index_file] if lookup_path.end_with?('/')

    @lookup[lookup_path] && @lookup[lookup_path][lang]
  end

  private

  def on_file_changed(_updated_files, _removed_files)
    @_langs = nil # Clear langs cache

    # TODO, add new file to ::I18n.load_path
    ::I18n.reload!
  end

  def configure_i18n
    ::I18n.load_path += app.files.by_type(:locales).files.map { |p| p[:full_path].to_s }
    ::I18n.reload!

    ::I18n.default_locale = @mount_at_root

    # Reset fallbacks to fall back to our new default
    ::I18n.fallbacks = ::I18n::Locale::Fallbacks.new if ::I18n.respond_to?(:fallbacks)
  end

  Contract ArrayOf[Symbol]
  def known_languages
    if options[:langs]
      Array(options[:langs]).map(&:to_sym)
    else
      known_langs = app.files.by_type(:locales).files.select do |p|
        p[:relative_path].to_s.split(File::SEPARATOR).length == 1
      end

      known_langs.map do |p|
        File.basename(p[:relative_path].to_s).sub(/\.ya?ml$/, '').sub(/\.rb$/, '')
      end.sort.map(&:to_sym)
    end
  end

  # Parse locale extension filename
  # @return [lang, path, basename]
  # will return +nil+ if no locale extension
  Contract String => Maybe[[Symbol, String, String]]
  def parse_locale_extension(path)
    path_bits = path.split('.')
    return nil if path_bits.size < 3

    lang = path_bits.delete_at(-2).to_sym
    return nil unless langs.include?(lang)

    path = path_bits.join('.')
    basename = File.basename(path_bits[0..-2].join('.'))
    [lang, path, basename]
  end

  LocalizedPageDescriptor = Struct.new(:path, :source_path, :lang) do
    def to_resource(app)
      r = ::Middleman::Sitemap::ProxyResource.new(app.sitemap, path, source_path)
      r.add_metadata options: { lang: lang }
      r
    end
  end

  Contract String, String, String, Symbol => LocalizedPageDescriptor
  def build_resource(path, source_path, page_id, lang)
    old_locale = ::I18n.locale
    ::I18n.locale = lang
    localized_page_id = ::I18n.t("paths.#{page_id}", default: page_id, fallback: [])

    partially_localized_path = ''

    File.dirname(path).split('/').each do |path_sub|
      next if path_sub == ''
      partially_localized_path = "#{partially_localized_path}/#{(::I18n.t("paths.#{path_sub}", default: path_sub).to_s)}"
    end

    path = "#{partially_localized_path}/#{File.basename(path)}"

    prefix = if (options[:mount_at_root] == lang) || (options[:mount_at_root].nil? && langs[0] == lang)
      '/'
    else
      replacement = options[:lang_map].fetch(lang, lang)
      options[:path].sub(':locale', replacement.to_s)
    end

    # path needs to be changed if file has a localizable extension. (options[mount_at_root] == lang)
    path = ::Middleman::Util.normalize_path(
      File.join(prefix, path.sub(page_id, localized_page_id))
    )

    path = path.sub(options[:templates_dir] + '/', '')

    ::I18n.locale = old_locale

    LocalizedPageDescriptor.new(path, source_path, lang)
  end
end
