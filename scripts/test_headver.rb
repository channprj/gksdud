require 'minitest/autorun'
require 'tmpdir'
require 'open3'
require 'fileutils'
require 'rbconfig'

class HeadverTest < Minitest::Test
  SCRIPT = File.expand_path('headver.rb', __dir__)
  MONDAY = '2026-11-23T00:00:00+09:00'

  def setup
    @dir = Dir.mktmpdir('gksdud-headver-test-')
    git('init', '-q', '-b', 'main')
    @state = File.join(@dir, '.git', 'headver', 'counter')
    @clock = File.join(@dir, 'clock.rb')
    File.write(@clock, "require 'time'\nclass << Time\n  def now; iso8601(ENV.fetch('HEADVER_TEST_TIME')); end\nend\n")
  end

  def teardown
    FileUtils.remove_entry(@dir)
  end

  def git(*args)
    out, err, status = Open3.capture3('git', *args, chdir: @dir)
    assert status.success?, out + err
    out.strip
  end

  def runver(now = MONDAY, chdir: @dir)
    Open3.capture3({ 'GIT_DIR' => nil, 'GIT_WORK_TREE' => nil, 'HEADVER_TEST_TIME' => now },
                  RbConfig.ruby, '-r', @clock, SCRIPT, chdir: chdir)
  end

  def reserve(now = MONDAY, chdir: @dir)
    out, err, status = runver(now, chdir: chdir)
    assert status.success?, err
    assert_empty err
    out.strip
  end

  def test_first_build_and_same_week_increment
    assert_equal '2.2648.0', reserve
    assert_equal '2.2648.1', reserve('2026-11-29T23:59:59+09:00')
  end

  def test_patch_resets_at_monday_midnight_in_seoul
    assert_equal '2.2647.0', reserve('2026-11-22T14:59:59Z')
    assert_equal '2.2647.1', reserve('2026-11-22T23:59:59+09:00')
    assert_equal '2.2648.0', reserve('2026-11-22T15:00:00Z')
  end

  def test_official_headver_iso_year_boundaries
    { '2012-01-01' => '1152', '2018-01-01' => '1801', '2018-01-02' => '1801',
      '2018-01-07' => '1801', '2018-01-06' => '1801', '2019-01-01' => '1901',
      '2015-01-01' => '1501', '2010-01-01' => '0953', '2018-12-31' => '1901',
      '2019-12-31' => '2001', '2009-12-31' => '0953', '2011-12-31' => '1152',
      '2017-12-31' => '1752', '2015-12-31' => '1553', '2016-01-01' => '1553',
      '2016-12-31' => '1652' }.each do |date, week|
      File.unlink(@state) if File.exist?(@state)
      assert_equal "2.#{week}.0", reserve("#{date}T12:00:00+09:00"), date
    end
  end

  def test_corrupt_state_is_preserved_and_refused
    FileUtils.mkdir_p(File.dirname(@state))
    ['', "nonsense\n", "2600 2\n", "2654 2\n", "2648 -1\n", "2648 01\n", "2648 1\nextra"].each do |raw|
      File.write(@state, raw)
      out, err, status = runver
      refute status.success?, "Accepted invalid state #{raw.inspect}"
      assert_empty out
      assert_match(/corrupt/, err)
      assert_equal raw, File.read(@state)
    end
  end

  def test_clock_rollback_cannot_reuse_a_reserved_number
    reserve('2026-11-30T00:00:00+09:00')
    previous = File.read(@state)
    out, err, status = runver
    refute status.success?
    assert_empty out
    assert_match(/clock moved backwards/, err)
    assert_equal previous, File.read(@state)
  end

  def test_concurrent_reservations_all_succeed_without_duplicates
    results = 8.times.map { Thread.new { runver } }.map(&:value)
    results.each { |_, err, status| assert status.success?, err }
    assert_equal (0...8).map { |n| "2.2648.#{n}" }.sort, results.map { |out, _, _| out.strip }.sort
  end

  def test_linked_worktrees_share_the_counter
    git('-c', 'user.name=HeadVer Test', '-c', 'user.email=test@example.invalid', 'commit', '--allow-empty', '-qm', 'Initial source')
    sibling = File.join(@dir, 'sibling')
    git('worktree', 'add', '-q', '-b', 'sibling', sibling)
    assert_equal '2.2648.0', reserve
    assert_equal '2.2648.1', reserve(chdir: sibling)
    assert_equal '2.2648.2', reserve
    git('worktree', 'remove', sibling)
  end
end
