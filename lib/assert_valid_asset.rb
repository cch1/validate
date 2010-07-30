require 'action_controller/test_process'
require 'action_mailer/test_case'
require 'net/http'
require 'digest'
require 'ftools'
require 'ping'
require 'rexml/rexml'
require 'rexml/document'

class Validator
  include Singleton

  MARKUP_VALIDATOR_HOST = ENV['MARKUP_VALIDATOR_HOST'] || 'validator.w3.org'
  MARKUP_VALIDATOR_PATH = ENV['MARKUP_VALIDATOR_PATH'] || '/check'
  CSS_VALIDATOR_HOST = ENV['CSS_VALIDATOR_HOST'] || 'jigsaw.w3.org'
  CSS_VALIDATOR_PATH = ENV['CSS_VALIDATOR_PATH'] || '/css-validator/validator'
  CSS_VALIDATOR_OPTIONS = {'warning' => '1', 'profile' => 'css2', 'usermedium' => 'all'}
  CACHE_DIR = File.join(Rails.root, 'tmp', 'validation')

  class_inheritable_accessor :display_invalid_content
  self.display_invalid_content = false

  def initialize
    File.makedirs(CACHE_DIR) unless File.exists?(CACHE_DIR)
  end

  def validate_markup(fragment, id)
    raise "Validation service disabled" if disabled?
    base_filename = cache_resource(id, fragment, 'html')

    return unless base_filename
    results_filename = base_filename + '.html' + '.results.dump'

    begin
      response = File.open(results_filename) do |f| Marshal.load(f) end
    rescue
      response = http.start(MARKUP_VALIDATOR_HOST).post2(MARKUP_VALIDATOR_PATH, "fragment=#{CGI.escape(fragment)}&output=xml")
      File.open(results_filename, 'w+') { |f| Marshal.dump(response, f) } if Net::HTTPSuccess === response
    end
    markup_is_valid = response['x-w3c-validator-status'] == 'Valid'
    return [] if markup_is_valid
    begin
      REXML::Document.new(response.body).root.elements.to_a("//ol[@id='error_loop']/li").collect do |e|
        text = e.text("span[@class='msg']").chomp
        position = /Line\s*(\d+).*Column\s*(\d+)/.match(e.text("em"))
        "Invalid markup @#{sprintf('%04i', position[1])}: #{CGI.unescapeHTML(text)}"
      end
    rescue => e
      ["<markup errors present, but not parseable: #{e}>"]
    end
  end

  def validate_css(css, id)
    raise "Validation service disabled" if disabled?
    base_filename = cache_resource(id, css, 'css')
    results_filename =  base_filename + '.css' + '.results.dump'
    begin
      response = File.open(results_filename) do |f| Marshal.load(f) end
    rescue
      params = CSS_VALIDATOR_OPTIONS.map{|(k,v)| text_to_multipart(k, v)}
      params << file_to_multipart('file','file.css','text/css',css)
      boundary = '-----------------------------24464570528145'
      query = params.collect { |p| '--' + boundary + "\r\n" + p }.join('') + '--' + boundary + "--\r\n"

      response = http.start(CSS_VALIDATOR_HOST).post2(CSS_VALIDATOR_PATH,query,"Content-type" => "multipart/form-data; boundary=" + boundary)
      File.open(results_filename, 'w+') { |f| Marshal.dump(response, f) } if Net::HTTPSuccess === response
    end
    messages = []
    begin
      REXML::XPath.each( REXML::Document.new(response.body).root, "//x:tr[@class='error']", { "x"=>"http://www.w3.org/1999/xhtml" }) do |element|
        messages << "Invalid CSS: line" + element.to_s.gsub(/<[^>]+>/,' ').gsub(/\n/,' ').gsub(/\s+/, ' ')
      end
    rescue REXML::ParseException
    end
    messages
  end

  def disabled?
    (ENV["NONET"] == 'true') || !internet_accessible? unless (ENV["NONET"] == 'false')
  end

  private
  # Determine if we have Internet access.  Note that this check depends on Ping standard library,
  # which does not use the proper ICMP echo service (which is a privileged operation) but rather a TCP
  # open of port 7 (echo).
  def internet_accessible?
    return @service_availability unless @service_availability.nil?
    @service_availability = returning(Ping.pingecho(MARKUP_VALIDATOR_HOST, 5)) do |available|
      $stderr << "#{MARKUP_VALIDATOR_HOST} not available.\n" unless available
    end
  end

  def text_to_multipart(key,value)
    return "Content-Disposition: form-data; name=\"#{CGI::escape(key)}\"\r\n\r\n#{value}\r\n"
  end

  def file_to_multipart(key,filename,mime_type,content)
    return "Content-Disposition: form-data; name=\"#{CGI::escape(key)}\"; filename=\"#{filename}\"\r\n" +
              "Content-Transfer-Encoding: binary\r\nContent-Type: #{mime_type}\r\n\r\n#{content}\r\n"
  end

  def cache_resource(id, resource, extension)
    resource_md5 = Digest::MD5.hexdigest(resource)

    base_filename = File.join(CACHE_DIR, id)
    filename = base_filename + ".#{extension}"
    file_md5 = File.exists?(filename) ? File.read(filename) : nil

    if file_md5 != resource_md5
      Dir["#{base_filename}\.*"].each {|f| File.delete(f)} # Remove previous results
      File.open(filename, 'w+') do |f| f.write(resource_md5); end # Cache new resource's hash
    end
    base_filename
  end

  def http
    if Module.constants.include?("ApplicationConfig") && ApplicationConfig.respond_to?(:proxy_config)
      Net::HTTP::Proxy(ApplicationConfig.proxy_config['host'], ApplicationConfig.proxy_config['port'])
    else
      Net::HTTP
    end
  end
end

class ActionMailer::TestCase
  class_inheritable_accessor :display_invalid_content

  def assert_valid_markup(fragment)
    return if Validator.instance.disabled?
    id = self.class.name.gsub(/\:\:/,'/').gsub(/Controllers\//,'') + '.' + method_name
    message = ""
    fragment.split($/).each_with_index{|line, index| message << "#{'%04i' % (index+1)} : #{line}#{$/}"} if display_invalid_content
    errors = Validator.instance.validate_markup(fragment, id)
    assert errors.empty?, message + errors.join("\n")
  end
end

class ActionController::TestCase
  class_inheritable_accessor :display_invalid_content
  class_inheritable_accessor :auto_validate
  class_inheritable_accessor :auto_validate_excludes
  class_inheritable_accessor :auto_validate_includes

  self.display_invalid_content = false
  self.auto_validate = false

  def process_with_auto_validate(action, parameters = nil, session = nil, flash = nil, http_method = "GET")
    response = process_without_auto_validate(action,parameters,session,flash, http_method)
    if auto_validate
      return if (auto_validate_excludes and auto_validate_excludes.include?(method_name.to_sym))
      return if (auto_validate_includes and not auto_validate_includes.include?(method_name.to_sym))
      # Rails generates bad html for redirects
      return if @response.redirect?
      ct = @response.headers['Content-Type']
      if ct.include?('text/html') or ct.include?('text/xhtml')
        assert_valid_markup
      elsif ct.include?('text/css')
        assert_valid_css
      end
    end
    response
  end

  alias_method_chain :process, :auto_validate

  # Assert that markup (html/xhtml) is valid according the W3C validator web service.
  # By default, it validates the contents of @response.body, which is set after calling
  # one of the get/post/etc helper methods. You can also pass it a string to be validated.
  # Validation errors, if any, will be included in the output. The input fragment and
  # response from the validator service will be cached in the $RAILS_ROOT/tmp directory to
  # minimize network calls.
  #
  # For example, if you have a FooController with an action Bar, put this in foo_controller_test.rb:
  #
  #   def test_bar_valid_markup
  #     get :bar
  #     assert_valid_markup
  #   end
  #
  def assert_valid_markup(fragment = @response.body, message = nil)
    return if Validator.instance.disabled?
    id = self.class.name.gsub(/\:\:/,'/').gsub(/Controllers\//,'') + '.' + method_name
    template = "? markup errors\n?\n#{'-' * 80}\n?"
    errors = Validator.instance.validate_markup(fragment, id)
    index = 0
    content = display_invalid_content ? AssertionMessage.literal(fragment.split($/).map{|line| "#{'%04i' % (index += 1)} : #{line}"}.join($/)) : ""
    assert_block(build_message(message, template, errors.size, AssertionMessage.literal(errors.join("\n")), content)) { errors.empty? }
  end

  # Class-level method to quickly create validation tests for a bunch of actions at once.
  # For example, if you have a FooController with three actions, just add one line to foo_controller_test.rb:
  #
  #   assert_valid_markup :bar, :baz, :qux
  #
  # If you pass :but_first => :something, #something will be called at the beginning of each test case
  def self.assert_valid_markup(*actions)
    options = actions.find { |i| i.kind_of? Hash }
    actions.delete_if { |i| i.kind_of? Hash }
    actions.each do |action|
      toeval = "def test_#{action}_valid_markup\n"
      toeval << "#{options[:but_first].id2name}\n" if options and options[:but_first]
      toeval << "get :#{action}\n"
      toeval << "assert_valid_markup\n"
      toeval << "end\n"
      class_eval toeval
    end
  end

  # Assert that css is valid according the W3C validator web service.
  # You pass the css as a string to the method. Validation errors, if any,
  # will be included in the output. The input fragment and response from
  # the validator service will be cached in the $RAILS_ROOT/tmp directory to
  # minimize network calls.
  #
  # For example, if you have a css file standard.css you can add the following test;
  #
  #   def test_standard_css
  #     assert_valid_css(File.open("#{RAILS_ROOT}/public/stylesheets/standard.css",'rb').read)
  #   end
  #
  def assert_valid_css(css = @response.body)
    return if Validator.instance.disabled?
    id = self.class.name.gsub(/\:\:/,'/').gsub(/Controllers\//,'') + '.' + method_name
    errors = Validator.instance.validate_css(css, id)
    assert errors.empty?, errors.join("\n")
  end

  # Class-level method to quickly create validation tests for a bunch of css files relative to
  # $RAILS_ROOT/public/stylesheets and ending in '.css'.
  #
  # The following example validates layout.css and standard.css in the standard directory ($RAILS_ROOT/public/stylesheets);
  #
  #   class CssTest < Test::Unit::TestCase
  #     assert_valid_css_files 'layout', 'standard'
  #   end
  #
  # Alternatively you can use the following to validate all your css files.
  #
  #   class CssTest < Test::Unit::TestCase
  #     assert_valid_css_files :all
  #   end
  #
  def self.assert_valid_css_files(*files)
    if files == [:all]
      files = Dir.glob("#{RAILS_ROOT}/public/stylesheets/*.css").map {|f| File.basename(f, ".css") }
    end
    files.each do |file|
      filename = "#{RAILS_ROOT}/public/stylesheets/#{file}.css"
      toeval = "def test_#{file.gsub(/[-.]/,'_')}_valid_css\n"
      toeval << "  assert_valid_css(File.open('#{filename}','rb').read)\n"
      toeval << "end\n"
      class_eval toeval
    end
  end
end