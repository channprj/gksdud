require 'minitest/autorun'
require 'tmpdir'
require 'open3'

class HeadverTest < Minitest::Test
  SCRIPT = File.expand_path('headver.rb', __dir__)
  def setup
    @dir = Dir.mktmpdir
    system('git', 'init', '-q', @dir) or flunk 'git init failed'
    @env = {'GIT_DIR' => File.join(@dir, '.git')}
    @state = File.join(@dir, '.git', 'headver', 'counter')
  end
  def teardown; FileUtils.remove_entry(@dir); end
  def runver
    Open3.capture3(@env, 'ruby', SCRIPT, chdir: @dir)
  end
  def setstate(s)
    FileUtils.mkdir_p(File.dirname(@state)); File.write(@state, s)
  end
  def test_increments_and_resets_weeks
    setstate("#{Time.now.getlocal('+09:00').strftime('%g%V')} 4\n")
    out, err, status = runver
    assert status.success?, err
    assert_equal 5, out.strip.split('.').last.to_i
    old = (Time.now.getlocal('+09:00') - 8*86400).strftime('%g%V')
    setstate("#{old} 99\n")
    out, err, status = runver
    assert status.success?, err
    assert_equal 0, out.strip.split('.').last.to_i
  end
  def test_bad_state_fails_closed
    setstate("nonsense\n")
    out, err, status = runver
    refute status.success?
    assert_empty out
    assert_match(/corrupt/, err)
  end
  def test_concurrent_reservations_unique
    outs = 8.times.map { Thread.new { runver.first } }.map(&:value)
    assert_equal 8, outs.uniq.size
  end
end
