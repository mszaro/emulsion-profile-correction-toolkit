require "rake/testtask"
require "rbconfig"

Rake::TestTask.new(:test) do |t|
  t.libs << "test"
  t.test_files = FileList["test/**/*_test.rb"]
end

task default: :test

# The helper behind --encoder apple. Built here, not at install, so that
# installing never needs a compiler.
HELPER = "libexec/apple-heic".freeze
HELPER_SOURCE = "ext/apple_heic/apple_heic.swift".freeze

file HELPER => HELPER_SOURCE do
  abort "--encoder apple is macOS only" unless RbConfig::CONFIG["host_os"].include?("darwin")
  mkdir_p File.dirname(HELPER)
  sh "swiftc", "-O", "-target", "#{RbConfig::CONFIG['host_cpu']}-apple-macos13", "-o", HELPER, HELPER_SOURCE
end

desc "Build the helper for --encoder apple (macOS, needs Xcode's command line tools)"
task apple_heic: HELPER
