# ~*~ encoding: utf-8 ~*~

# Render all tags (things in double-square-brackets).  This one's a biggie.
class Gollum::Filter::Tags < Gollum::Filter
  # Extract all tags into the tagmap and replace with placeholders.
  def extract(data)
    return data if @markup.format == :txt || @markup.format == :asciidoc
    data.gsub!(/(.?)\[\[(.+?)\]\]([^\[]?)/m) do
      if $1 == "'" && $3 != "'"
        "[[#{$2}]]#{$3}"
      elsif $2.include?('][')
        if $2[0..4] == 'file:'
          pre = $1
          post = $3
          parts = $2.split('][')
          parts[0][0..4] = ""
          link = "#{parts[1]}|#{parts[0].sub(/\.org/,'')}"
          id = Digest::SHA1.hexdigest(link)
          @map[id] = link
          "#{pre}#{id}#{post}"
        else
          $&
        end
      else
        id = Digest::SHA1.hexdigest($2)
        @map[id] = $2
        "#{$1}#{id}#{$3}"
      end
    end
    data
  end

  # Process all tags from the tagmap and replace the placeholders with the
  # final markup.
  def process(data)
    @map.each do |id, tag|
      # If it's preformatted, just put the tag back
      if is_preformatted?(data, id)
        data.gsub!(id) do
          "[[#{tag}]]"
        end
      else
        data.gsub!(id) do
          process_tag(tag).gsub('%2F', '/')
        end
      end
    end

    data
  end

  private
  # Find `id` within `data` and determine if it's within
  # preformatted tags.
  #
  # data      - The String data (with placeholders).
  # id        - The String SHA1 hash.
  PREFORMATTED_TAGS = %w(code tt)
  def is_preformatted?(data, id)
    doc = Nokogiri::HTML::DocumentFragment.parse(data)
    node = doc.search("[text()*='#{id}']").first
    node && (PREFORMATTED_TAGS.include?(node.name) ||
      node.ancestors.any? { |a| PREFORMATTED_TAGS.include?(a.name) })
  end

  # Process a single tag into its final HTML form.
  #
  # tag       - The String tag contents (the stuff inside the double
  #             brackets).
  #
  # Returns the String HTML version of the tag.
  def process_tag(tag)
    if tag =~ /^_TOC_$/
      %{[[#{tag}]]}
    elsif tag =~ /^_$/
      %{<div class="clearfloats"></div>}
    elsif html = process_include_tag(tag)
      html
    elsif html = process_image_tag(tag)
      html
    elsif html = process_file_link_tag(tag)
      html
    else
      process_page_link_tag(tag)
    end
  end
  
  # Attempt to process the tag as an include tag
  #
  # tag - The String tag contents (the  stuff inside the double brackets).
  #
  # Returns the String HTML if the tag is a valid image tag or nil
  #   if it is not.
  #
  def process_include_tag(tag)
    return unless /^include:/.match(tag)
    page_name = tag[8..-1]

    if @markup.include_levels > 0
      page = @markup.wiki.page(page_name)
      if page
        page.formatted_data(@markup.encoding, @markup.include_levels-1)
      else
        html_error("Cannot include #{process_page_link_tag(page_name)} - does not exist yet")
      end
    else
      html_error("Too many levels of included pages, will not include #{process_page_link_tag(page_name)}")
    end
  end

  # Attempt to process the tag as an image tag.
  #
  # tag - The String tag contents (the stuff inside the double brackets).
  #
  # Returns the String HTML if the tag is a valid image tag or nil
  #   if it is not.
  def process_image_tag(tag)
    parts = tag.split('|')
    return if parts.size.zero?

    name  = parts[0].strip
    path  = if file = @markup.find_file(name)
      ::File.join @markup.wiki.base_path, file.path
    elsif name =~ /^https?:\/\/.+(jpg|png|gif|svg|bmp)$/i
      name
    end

    if path
      opts = parse_image_tag_options(tag)

      containered = false

      classes = [] # applied to whatever the outermost container is
      attrs   = [] # applied to the image

      align = opts['align']
      if opts['float']
        containered = true
        align ||= 'left'
        if %w{left right}.include?(align)
          classes << "float-#{align}"
        end
      elsif %w{top texttop middle absmiddle bottom absbottom baseline}.include?(align)
        attrs << %{align="#{align}"}
      elsif align
        if %w{left center right}.include?(align)
          containered = true
          classes << "align-#{align}"
        end
      end

      if width = opts['width']
        if width =~ /^\d+(\.\d+)?(em|px)$/
          attrs << %{width="#{width}"}
        end
      end

      if height = opts['height']
        if height =~ /^\d+(\.\d+)?(em|px)$/
          attrs << %{height="#{height}"}
        end
      end

      if alt = opts['alt']
        attrs << %{alt="#{alt}"}
      end

      attr_string = attrs.size > 0 ? attrs.join(' ') + ' ' : ''

      if opts['frame'] || containered
        classes << 'frame' if opts['frame']
        %{<span class="#{classes.join(' ')}">} +
        %{<span>} +
        %{<img src="#{path}" #{attr_string}/>} +
        (alt ? %{<span>#{alt}</span>} : '') +
        %{</span>} +
        %{</span>}
      else
        %{<img src="#{path}" #{attr_string}/>}
      end
    end
  end

  # Parse any options present on the image tag and extract them into a
  # Hash of option names and values.
  #
  # tag - The String tag contents (the stuff inside the double brackets).
  #
  # Returns the options Hash:
  #   key - The String option name.
  #   val - The String option value or true if it is a binary option.
  def parse_image_tag_options(tag)
    tag.split('|')[1..-1].inject({}) do |memo, attr|
      parts = attr.split('=').map { |x| x.strip }
      memo[parts[0]] = (parts.size == 1 ? true : parts[1])
      memo
    end
  end

  # Attempt to process the tag as a file link tag.
  #
  # tag       - The String tag contents (the stuff inside the double
  #             brackets).
  #
  # Returns the String HTML if the tag is a valid file link tag or nil
  #   if it is not.
  def process_file_link_tag(tag)
    parts = tag.split('|')
    return if parts.size.zero?

    name  = parts[0].strip
    path  = parts[1] && parts[1].strip
    path  = if path && file = @markup.find_file(path)
      ::File.join @markup.wiki.base_path, file.path
    elsif path =~ %r{^https?://}
      path
    else
      nil
    end

    if name && path && file
      %{<a href="#{::File.join @markup.wiki.base_path, file.path}">#{name}</a>}
    elsif name && path
      %{<a href="#{path}">#{name}</a>}
    else
      nil
    end
  end

  # Attempt to process the tag as a page link tag.
  #
  # tag       - The String tag contents (the stuff inside the double
  #             brackets).
  #
  # Returns the String HTML if the tag is a valid page link tag or nil
  #   if it is not.
  def process_page_link_tag(tag)
    parts = tag.split('|')
    parts.reverse! if @markup.format == :mediawiki

    name, page_name = *parts.compact.map(&:strip)
    cname = @markup.wiki.page_class.cname(page_name || name)

    if name =~ %r{^https?://} && page_name.nil?
      %{<a href="#{name}">#{name}</a>}
    else
      presence    = "absent"
      link_name   = cname
      page, extra = find_page_from_name(cname)
      if page
        link_name = @markup.wiki.page_class.cname(page.name)
        presence  = "present"
      end
      link = ::File.join(@markup.wiki.base_path, page ? page.escaped_url_path : CGI.escape(link_name))

      # //page is invalid
      # strip all duplicate forward slashes using helpers.rb trim_leading_slash
      # //page => /page
      link = trim_leading_slash link

      %{<a class="internal #{presence}" href="#{link}#{extra}">#{name}</a>}
    end
  end

  # Find a page from a given cname.  If the page has an anchor (#) and has
  # no match, strip the anchor and try again.
  #
  # cname - The String canonical page name including path.
  #
  # Returns a Gollum::Page instance if a page is found, or an Array of
  # [Gollum::Page, String extra] if a page without the extra anchor data
  # is found.
  def find_page_from_name(cname)
    slash = cname.rindex('/')

    unless slash.nil?
      name = cname[slash+1..-1]
      path = cname[0..slash]
      page = @markup.wiki.paged(name, path)
    else
      page = @markup.wiki.paged(cname, '/') || @markup.wiki.page(cname)
    end

    if page
      return page
    end
    if pos = cname.index('#')
      [@markup.wiki.page(cname[0...pos]), cname[pos..-1]]
    end
  end
end
