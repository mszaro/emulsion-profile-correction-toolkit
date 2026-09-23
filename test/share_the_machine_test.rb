require_relative "test_helper"
require "open3"
require "etc"

class ShareTheMachineTest < Minitest::Test
  LIB = File.expand_path("../lib/emulsion", __dir__)

  # Run the command line in a child, since --gentle lowers the priority of the
  # process it runs in and that should not follow the rest of the suite.
  def settings_after(*flags)
    script = <<~RUBY
      require #{LIB.inspect}
      require #{(LIB + "/cli").inspect}
      $stderr.reopen(File::NULL)
      Emulsion::CLI.run(#{flags.inspect})
      puts Vips.concurrency, Process.getpriority(Process::PRIO_PROCESS, 0)
    RUBY
    out, status = Open3.capture2("ruby", "-e", script)
    assert status.success?, "the child process should run"
    out.split.map(&:to_i)
  end

  def test_by_default_every_core_is_used_at_normal_priority
    threads, niceness = settings_after
    assert_equal Etc.nprocessors, threads
    assert_equal 0, niceness
  end

  def test_threads_caps_the_image_work
    threads, niceness = settings_after("--threads", "4")
    assert_equal 4, threads
    assert_equal 0, niceness, "a thread cap alone leaves the priority alone"
  end

  def test_gentle_takes_half_the_cores_at_low_priority
    threads, niceness = settings_after("--gentle")
    assert_equal [Etc.nprocessors / 2, 1].max, threads
    assert_equal Emulsion::CLI::GENTLE_NICENESS, niceness
  end

  def test_an_explicit_thread_count_wins_over_gentle
    threads, = settings_after("--gentle", "--threads", "3")
    assert_equal 3, threads
  end
end
