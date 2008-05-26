require 'rubygems'
gem 'actionpack'

require 'test/unit'
require 'assert_valid_asset'

FixturePath = File.join File.dirname(__FILE__), 'fixtures/'

class AssertValidAssetTest < Test::Unit::TestCase

  self.display_invalid_content = false

  def test_valid_markup
    assert_valid_markup File.read( File.join( FixturePath, 'valid.xhtml' ) )
  end

  def test_valid_css
    assert_valid_css File.read( File.join( FixturePath, 'valid.css' ) )
  end

  def test_invalid_markup
    begin
      assert_valid_markup File.read( File.join( FixturePath, 'invalid.xhtml' ) )

    rescue Test::Unit::AssertionFailedError => ex
      reasons = ex.to_s
      assert_match /line 13: element "fnord" undefined/, reasons
      assert_match /line 18: end tag for "div" omitted/, reasons

    else
      flunk 'Invalid markup passed validation'
    end
  end

  def test_invalid_css
    begin
      assert_valid_css File.read( File.join( FixturePath, 'invalid.css' ) )

    rescue Test::Unit::AssertionFailedError => ex
      reasons = ex.to_s
      assert_match /line 2 Unrecognized 123fnord/, reasons
      assert_match /line 7 body Property bogosity/, reasons

    else
      flunk 'Invalid CSS passed validation'
    end
  end

end
RAILS_ROOT = File.dirname( File.dirname(__FILE__) )