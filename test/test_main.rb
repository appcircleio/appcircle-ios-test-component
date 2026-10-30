# frozen_string_literal: true

# ─── Coverage (must start before loading main.rb) ─────────────────────────────
unless defined?(Coverage) && Coverage.running?
  require 'coverage'
  Coverage.start
end

# ─── Dependencies ─────────────────────────────────────────────────────────────
require 'rspec'
require 'rspec/core/formatters/base_formatter'
require 'open3'
require 'fileutils'
require 'tmpdir'
require 'pathname'
require 'stringio'
require 'rbconfig'
require 'English'

MAIN_RB      = File.expand_path('../main.rb', __dir__)
PROJECT_ROOT = File.dirname(MAIN_RB)

# Top-level execution in main.rb is guarded by `__FILE__ == $PROGRAM_NAME`,
# so requiring it only defines the functions under test.
require MAIN_RB

# ─── Custom Formatter ─────────────────────────────────────────────────────────
class ReadableFormatter < RSpec::Core::Formatters::BaseFormatter
  RSpec::Core::Formatters.register(
    self,
    :example_group_started,
    :example_group_finished,
    :example_passed,
    :example_failed,
    :example_pending,
    :dump_summary
  )

  PASS  = "\e[32;1m[ PASS ]\e[0m"
  FAIL  = "\e[31;1m[ FAIL ]\e[0m"
  ERROR = "\e[31;1m[ERROR ]\e[0m"
  SKIP  = "\e[33;1m[ SKIP ]\e[0m"

  DIVIDER     = "\e[90m#{'─' * 72}\e[0m"
  DIVIDER_FAT = "\e[90m#{'═' * 72}\e[0m"

  GROUP_COLORS = [
    "\e[34;1m",  # bold blue
    "\e[35;1m",  # bold magenta
    "\e[36;1m",  # bold cyan
    "\e[33;1m",  # bold yellow
  ].freeze

  def initialize(output)
    super
    @depth    = 0
    @top_idx  = -1
    @failures = []
    @counts   = { passed: 0, failed: 0, pending: 0 }
  end

  def example_group_started(notification)
    group = notification.group
    if group.parent_groups.size <= 1
      output.puts if @depth.zero?
      @top_idx = (@top_idx + 1) % GROUP_COLORS.size
      output.puts "  #{GROUP_COLORS[@top_idx]}#{group.description}\e[0m"
    else
      output.puts "    #{'  ' * (@depth - 1)}\e[90m▸ \e[0m\e[37m#{group.description}\e[0m"
    end
    @depth += 1
  end

  def example_group_finished(_notification)
    @depth -= 1 if @depth > 0
  end

  def example_passed(notification)
    @counts[:passed] += 1
    print_example(PASS, notification.example)
  end

  def example_failed(notification)
    @counts[:failed] += 1
    ex    = notification.example
    exc   = ex.execution_result.exception
    badge = exc.is_a?(RSpec::Expectations::ExpectationNotMetError) ? FAIL : ERROR
    print_example(badge, ex)
    @failures << notification
  end

  def example_pending(notification)
    @counts[:pending] += 1
    ex = notification.example
    output.puts "    #{'  ' * [0, @depth - 1].max}#{SKIP}  #{ex.description}"
  end

  def dump_summary(notification)
    output.puts
    output.puts DIVIDER_FAT

    unless @failures.empty?
      output.puts "\n  \e[1;31mFailures:\e[0m\n"
      @failures.each_with_index do |n, i|
        ex  = n.example
        exc = ex.execution_result.exception
        output.puts "  \e[1m#{i + 1}) #{ex.full_description}\e[0m"
        exc.message.lines.first(6).each do |line|
          output.puts "     \e[31m#{line.rstrip}\e[0m"
        end
        output.puts "     \e[90m# #{ex.location}\e[0m"
        output.puts
      end
      output.puts DIVIDER
    end

    t   = notification.examples.size
    p   = @counts[:passed]
    f   = @counts[:failed]
    s   = @counts[:pending]
    sec = format('%.3fs', notification.duration)

    parts = ["\e[32m#{p} passed\e[0m"]
    parts << "\e[31m#{f} failed\e[0m"  if f > 0
    parts << "\e[33m#{s} pending\e[0m" if s > 0

    overall = f.zero? ? "\e[32;1m✔  All #{t} tests passed\e[0m" : "\e[31;1m✖  #{f} of #{t} tests failed\e[0m"
    output.puts "\n  #{overall}"
    output.puts "  #{parts.join('  |  ')}  \e[90m(#{sec})\e[0m"
    output.puts DIVIDER_FAT
  end

  private

  def print_example(badge, example)
    indent = '  ' * [0, @depth - 1].max
    time   = format('%.3fs', example.execution_result.run_time)
    output.puts "    #{indent}#{badge}  #{example.description}  \e[90m(#{time})\e[0m"
  end
end

# ─── Subprocess Helpers ───────────────────────────────────────────────────────

# A fake `xcodebuild` that succeeds, so the step can be driven end-to-end
# without the real toolchain.
XCODEBUILD_STUB_SOURCE = <<~SH
  #!/bin/sh
  echo "stub-xcodebuild invoked"
  exit 0
SH

# A fake `xcodebuild` that fails, to exercise the run_command_simple error branch.
XCODEBUILD_FAILING_STUB_SOURCE = <<~SH
  #!/bin/sh
  echo "stub-xcodebuild failure details" >&2
  exit 65
SH

def with_xcodebuild_stub(source = XCODEBUILD_STUB_SOURCE)
  stub_dir = Dir.mktmpdir('xcodebuild_stub')
  stub     = File.join(stub_dir, 'xcodebuild')
  File.write(stub, source)
  FileUtils.chmod(0o755, stub)
  yield stub_dir
ensure
  FileUtils.rm_rf(stub_dir)
end

# Run main.rb in a child process with a controlled ENV.
# Keys left as nil are explicitly unset in the child, which isolates the
# missing-variable tests from the ambient environment.
def run_main(env = {}, stub_source: XCODEBUILD_STUB_SOURCE)
  with_xcodebuild_stub(stub_source) do |stub_dir|
    clean_env = {
      'AC_TEMP_DIR'                    => nil,
      'AC_PROJECT_PATH'                => nil,
      'AC_REPOSITORY_DIR'              => nil,
      'AC_SCHEME'                      => nil,
      'AC_OUTPUT_DIR_PATH'             => nil,
      'AC_TEST_OS_VERSION'             => nil,
      'AC_TEST_DEVICE'                 => nil,
      'AC_TEST_PLATFORM'               => nil,
      'AC_CONFIGURATION_NAME'          => nil,
      'AC_ARCHIVE_FLAGS'               => nil,
      'AC_COMPILER_INDEX_STORE_ENABLE' => nil,
      'AC_ENV_FILE_PATH'               => nil,
      'PATH'                           => "#{stub_dir}:#{ENV.fetch('PATH', '')}"
    }.merge(env)

    Open3.capture3(clean_env, "ruby #{MAIN_RB}")
  end
end

# Every variable main.rb needs to reach the xcodebuild call.
def full_env(tmpdir)
  {
    'AC_TEMP_DIR'                    => tmpdir,
    'AC_PROJECT_PATH'                => 'App.xcodeproj',
    'AC_SCHEME'                      => 'MyScheme',
    'AC_OUTPUT_DIR_PATH'             => File.join(tmpdir, 'output'),
    'AC_TEST_OS_VERSION'             => '17.0',
    'AC_TEST_DEVICE'                 => 'iPhone 15',
    'AC_TEST_PLATFORM'               => 'iOS Simulator',
    'AC_COMPILER_INDEX_STORE_ENABLE' => 'NO',
    'AC_ENV_FILE_PATH'               => File.join(tmpdir, 'env_file')
  }
end

# The "@@[command] ..." line main.rb prints before shelling out.
def composed_command(stdout)
  stdout[/^@@\[command\] (.*)$/, 1].to_s
end

# ─── Tests ────────────────────────────────────────────────────────────────────

# ─── 1. env_has_key ───────────────────────────────────────────────────────────
RSpec.describe '#env_has_key' do
  around do |example|
    had = ENV.key?('_AC_TEST_VAR')
    old = ENV['_AC_TEST_VAR']
    example.run
    had ? ENV['_AC_TEST_VAR'] = old : ENV.delete('_AC_TEST_VAR')
  end

  before { allow($stderr).to receive(:write) }

  context 'positive path' do
    it 'returns the value when the key is set' do
      ENV['_AC_TEST_VAR'] = 'hello'
      expect(env_has_key('_AC_TEST_VAR')).to eq('hello')
    end

    it 'returns a path-like value unchanged' do
      ENV['_AC_TEST_VAR'] = '/tmp/some/path'
      expect(env_has_key('_AC_TEST_VAR')).to eq('/tmp/some/path')
    end

    it 'returns a value that only contains whitespace' do
      ENV['_AC_TEST_VAR'] = ' '
      expect(env_has_key('_AC_TEST_VAR')).to eq(' ')
    end

    it 'returns the value verbatim, without trimming' do
      ENV['_AC_TEST_VAR'] = '  spaced  '
      expect(env_has_key('_AC_TEST_VAR')).to eq('  spaced  ')
    end
  end

  context 'negative path' do
    it 'aborts when the key is missing' do
      ENV.delete('_AC_TEST_VAR')
      expect { env_has_key('_AC_TEST_VAR') }.to raise_error(SystemExit)
    end

    it 'aborts when the value is an empty string' do
      ENV['_AC_TEST_VAR'] = ''
      expect { env_has_key('_AC_TEST_VAR') }.to raise_error(SystemExit)
    end

    it 'names the missing key in the abort message' do
      ENV.delete('_AC_TEST_VAR')
      expect { env_has_key('_AC_TEST_VAR') }
        .to raise_error(SystemExit, /Missing _AC_TEST_VAR\./)
    end

    it 'writes the abort message to stderr' do
      ENV.delete('_AC_TEST_VAR')
      captured        = StringIO.new
      original_stderr = $stderr
      $stderr         = captured
      begin
        env_has_key('_AC_TEST_VAR')
      rescue SystemExit
        # expected
      ensure
        $stderr = original_stderr
      end
      expect(captured.string).to match(/Missing _AC_TEST_VAR\./)
    end

    it 'exits with a non-zero status' do
      ENV.delete('_AC_TEST_VAR')
      expect { env_has_key('_AC_TEST_VAR') }
        .to raise_error(SystemExit) { |e| expect(e.status).not_to eq(0) }
    end

    it 'raises TypeError when the key itself is nil' do
      expect { env_has_key(nil) }.to raise_error(TypeError)
    end
  end
end

# ─── 2. abort_script ──────────────────────────────────────────────────────────
RSpec.describe '#abort_script' do
  before { allow($stderr).to receive(:write) }

  context 'positive path' do
    it 'raises SystemExit' do
      expect { abort_script('fatal error') }.to raise_error(SystemExit)
    end

    it 'carries the error text in the abort message' do
      expect { abort_script('fatal error') }.to raise_error(SystemExit, /fatal error/)
    end

    it 'exits with a non-zero status' do
      expect { abort_script('boom') }
        .to raise_error(SystemExit) { |e| expect(e.status).not_to eq(0) }
    end

    it 'never returns a value' do
      result = nil
      begin
        result = abort_script('boom')
      rescue SystemExit
        # expected
      end
      expect(result).to be_nil
    end
  end

  context 'negative path' do
    it 'still raises SystemExit for an empty message' do
      expect { abort_script('') }.to raise_error(SystemExit)
    end

    it 'still raises SystemExit for a nil message' do
      expect { abort_script(nil) }.to raise_error(SystemExit)
    end

    it 'stringifies a non-string argument instead of failing' do
      expect { abort_script(RuntimeError.new('err')) }.to raise_error(SystemExit, /err/)
    end
  end
end

# ─── 3. run_command_simple ────────────────────────────────────────────────────
RSpec.describe '#run_command_simple' do
  let(:tmpdir)      { Dir.mktmpdir('ac_rcs_test') }
  let(:stderr_log)  { File.join(tmpdir, '.command.stderr.log') }

  around do |example|
    had = ENV.key?('AC_TEMP_DIR')
    old = ENV['AC_TEMP_DIR']
    ENV['AC_TEMP_DIR'] = tmpdir
    example.run
    had ? ENV['AC_TEMP_DIR'] = old : ENV.delete('AC_TEMP_DIR')
    FileUtils.rm_rf(tmpdir)
  end

  before { allow($stderr).to receive(:write) }

  context 'positive path' do
    it 'returns without raising for a zero-exit command' do
      expect { run_command_simple(+'true') }.not_to raise_error
    end

    it 'echoes the command before running it' do
      expect { run_command_simple(+'true') }.to output(/@@\[command\] true/).to_stdout
    end

    it 'echoes the command without the stderr redirection' do
      expect { run_command_simple(+'true') }.not_to output(/@@\[command\].*2>/).to_stdout
    end

    it 'redirects stderr into the log file inside AC_TEMP_DIR' do
      run_command_simple(+'sh -c "echo noise >&2"')
      expect(File.read(stderr_log)).to include('noise')
    end

    it 'succeeds for a command that writes to stderr but exits zero' do
      expect { run_command_simple(+'sh -c "echo noise >&2; exit 0"') }.not_to raise_error
    end

    it 'returns nil on success' do
      expect(run_command_simple(+'true')).to be_nil
    end
  end

  context 'negative path' do
    it 'aborts when the command exits non-zero' do
      expect { run_command_simple(+'false') }.to raise_error(SystemExit)
    end

    it 'reports the exit code of the failed command' do
      expect { run_command_simple(+'sh -c "exit 42"') }
        .to raise_error(SystemExit, /Unexpected exit with code 42/)
    end

    it 'prints the captured stderr of the failed command' do
      expect do
        begin
          run_command_simple(+'sh -c "echo failure details >&2; exit 1"')
        rescue SystemExit
          # expected
        end
      end.to output(/failure details/).to_stdout
    end

    it 'aborts for a non-existent command' do
      expect { run_command_simple(+'ac_definitely_not_a_real_binary_xyz') }
        .to raise_error(SystemExit)
    end

    it 'does not abort for an empty command – the shell runs a bare redirection' do
      expect { run_command_simple(+'') }.not_to raise_error
    end

    it 'raises FrozenError for a frozen command string' do
      expect { run_command_simple('true'.freeze) }.to raise_error(FrozenError)
    end

    it 'raises NoMethodError for a nil command' do
      expect { run_command_simple(nil) }.to raise_error(NoMethodError)
    end
  end
end

# ─── 4. ENV validation (subprocess – main.rb) ─────────────────────────────────
RSpec.describe 'ENV validation (subprocess – main.rb)' do
  let(:tmpdir) { Dir.mktmpdir('ios_test_env') }
  after { FileUtils.rm_rf(tmpdir) }

  shared_examples 'aborts with message' do |expected_pattern, env|
    it "exits non-zero and stderr matches /#{expected_pattern}/" do
      _out, err, status = run_main(env)
      expect(status.exitstatus).not_to eq(0)
      expect(err).to match(Regexp.new(expected_pattern))
    end
  end

  context 'AC_TEMP_DIR' do
    context 'when missing' do
      include_examples 'aborts with message', 'Missing AC_TEMP_DIR\.', {}
    end

    context 'when an empty string' do
      include_examples 'aborts with message',
                       'Missing AC_TEMP_DIR\.',
                       { 'AC_TEMP_DIR' => '' }
    end
  end

  context 'AC_PROJECT_PATH' do
    context 'when missing' do
      include_examples 'aborts with message',
                       'Missing AC_PROJECT_PATH\.',
                       { 'AC_TEMP_DIR' => '/tmp' }
    end

    context 'when an empty string' do
      # main.rb only nil-checks this variable, so an empty value passes through
      # and the run stops at the next unset required variable instead.
      include_examples 'aborts with message',
                       'Missing AC_SCHEME\.',
                       { 'AC_TEMP_DIR' => '/tmp', 'AC_PROJECT_PATH' => '' }
    end
  end

  context 'AC_SCHEME' do
    context 'when missing' do
      include_examples 'aborts with message',
                       'Missing AC_SCHEME\.',
                       { 'AC_TEMP_DIR' => '/tmp', 'AC_PROJECT_PATH' => 'App.xcodeproj' }
    end

    context 'when an empty string' do
      include_examples 'aborts with message',
                       'Missing AC_SCHEME\.',
                       {
                         'AC_TEMP_DIR'     => '/tmp',
                         'AC_PROJECT_PATH' => 'App.xcodeproj',
                         'AC_SCHEME'       => ''
                       }
    end
  end

  context 'AC_OUTPUT_DIR_PATH' do
    let(:base) do
      { 'AC_TEMP_DIR' => '/tmp', 'AC_PROJECT_PATH' => 'App.xcodeproj', 'AC_SCHEME' => 'MyScheme' }
    end

    it 'aborts when missing' do
      _out, err, status = run_main(base)
      expect(status.exitstatus).not_to eq(0)
      expect(err).to match(/Missing AC_OUTPUT_DIR_PATH\./)
    end

    it 'aborts when an empty string' do
      _out, err, status = run_main(base.merge('AC_OUTPUT_DIR_PATH' => ''))
      expect(status.exitstatus).not_to eq(0)
      expect(err).to match(/Missing AC_OUTPUT_DIR_PATH\./)
    end
  end

  context 'AC_TEST_OS_VERSION' do
    let(:base) do
      {
        'AC_TEMP_DIR'        => '/tmp',
        'AC_PROJECT_PATH'    => 'App.xcodeproj',
        'AC_SCHEME'          => 'MyScheme',
        'AC_OUTPUT_DIR_PATH' => '/tmp/output'
      }
    end

    it 'aborts when missing' do
      _out, err, status = run_main(base)
      expect(status.exitstatus).not_to eq(0)
      expect(err).to match(/Missing AC_TEST_OS_VERSION\./)
    end

    it 'aborts when an empty string' do
      _out, err, status = run_main(base.merge('AC_TEST_OS_VERSION' => ''))
      expect(status.exitstatus).not_to eq(0)
      expect(err).to match(/Missing AC_TEST_OS_VERSION\./)
    end
  end

  context 'AC_TEST_DEVICE' do
    let(:base) do
      {
        'AC_TEMP_DIR'        => '/tmp',
        'AC_PROJECT_PATH'    => 'App.xcodeproj',
        'AC_SCHEME'          => 'MyScheme',
        'AC_OUTPUT_DIR_PATH' => '/tmp/output',
        'AC_TEST_OS_VERSION' => '17.0'
      }
    end

    it 'aborts when missing' do
      _out, err, status = run_main(base)
      expect(status.exitstatus).not_to eq(0)
      expect(err).to match(/Missing AC_TEST_DEVICE\./)
    end

    it 'aborts when an empty string' do
      _out, err, status = run_main(base.merge('AC_TEST_DEVICE' => ''))
      expect(status.exitstatus).not_to eq(0)
      expect(err).to match(/Missing AC_TEST_DEVICE\./)
    end
  end

  context 'AC_TEST_PLATFORM' do
    let(:base) do
      {
        'AC_TEMP_DIR'        => '/tmp',
        'AC_PROJECT_PATH'    => 'App.xcodeproj',
        'AC_SCHEME'          => 'MyScheme',
        'AC_OUTPUT_DIR_PATH' => '/tmp/output',
        'AC_TEST_OS_VERSION' => '17.0',
        'AC_TEST_DEVICE'     => 'iPhone 15'
      }
    end

    it 'aborts when missing' do
      _out, err, status = run_main(base)
      expect(status.exitstatus).not_to eq(0)
      expect(err).to match(/Missing AC_TEST_PLATFORM\./)
    end

    it 'aborts when an empty string' do
      _out, err, status = run_main(base.merge('AC_TEST_PLATFORM' => ''))
      expect(status.exitstatus).not_to eq(0)
      expect(err).to match(/Missing AC_TEST_PLATFORM\./)
    end
  end

  context 'AC_COMPILER_INDEX_STORE_ENABLE' do
    let(:base) do
      {
        'AC_TEMP_DIR'        => '/tmp',
        'AC_PROJECT_PATH'    => 'App.xcodeproj',
        'AC_SCHEME'          => 'MyScheme',
        'AC_OUTPUT_DIR_PATH' => '/tmp/output',
        'AC_TEST_OS_VERSION' => '17.0',
        'AC_TEST_DEVICE'     => 'iPhone 15',
        'AC_TEST_PLATFORM'   => 'iOS Simulator'
      }
    end

    it 'aborts when missing' do
      _out, err, status = run_main(base)
      expect(status.exitstatus).not_to eq(0)
      expect(err).to match(/Missing AC_COMPILER_INDEX_STORE_ENABLE\./)
    end

    it 'aborts when an empty string' do
      _out, err, status = run_main(base.merge('AC_COMPILER_INDEX_STORE_ENABLE' => ''))
      expect(status.exitstatus).not_to eq(0)
      expect(err).to match(/Missing AC_COMPILER_INDEX_STORE_ENABLE\./)
    end
  end

  context 'AC_ENV_FILE_PATH' do
    it 'writes AC_TEST_RESULT_PATH when set' do
      env_file = File.join(tmpdir, 'env_file')
      _out, err, status = run_main(full_env(tmpdir))
      expect(status.exitstatus).to eq(0), "stderr was: #{err}"
      expect(File.read(env_file))
        .to include("AC_TEST_RESULT_PATH=#{File.join(tmpdir, 'output')}/test.xcresult")
    end

    it 'appends to an existing env file rather than truncating it' do
      env_file = File.join(tmpdir, 'env_file')
      File.write(env_file, "PRE_EXISTING=1\n")
      _out, _err, status = run_main(full_env(tmpdir))
      expect(status.exitstatus).to eq(0)
      expect(File.read(env_file)).to include('PRE_EXISTING=1')
    end

    it 'fails with a TypeError when missing' do
      _out, err, status = run_main(full_env(tmpdir).merge('AC_ENV_FILE_PATH' => nil))
      expect(status.exitstatus).not_to eq(0)
      expect(err).to match(/TypeError|no implicit conversion/)
    end

    it 'fails with a missing-file error when an empty string' do
      _out, err, status = run_main(full_env(tmpdir).merge('AC_ENV_FILE_PATH' => ''))
      expect(status.exitstatus).not_to eq(0)
      expect(err).to match(/No such file or directory|Errno::ENOENT/)
    end

    it 'fails when it points into a directory that does not exist' do
      _out, err, status = run_main(
        full_env(tmpdir).merge('AC_ENV_FILE_PATH' => File.join(tmpdir, 'no', 'such', 'dir', 'env'))
      )
      expect(status.exitstatus).not_to eq(0)
      expect(err).to match(/No such file or directory|Errno::ENOENT/)
    end
  end

  context 'AC_REPOSITORY_DIR (optional)' do
    it 'uses the bare project path when missing' do
      out, _err, status = run_main(full_env(tmpdir))
      expect(status.exitstatus).to eq(0)
      expect(composed_command(out)).to include('-project "App.xcodeproj"')
    end

    it 'uses the bare project path when an empty string' do
      out, _err, status = run_main(full_env(tmpdir).merge('AC_REPOSITORY_DIR' => ''))
      expect(status.exitstatus).to eq(0)
      expect(composed_command(out)).to include('-project "App.xcodeproj"')
    end

    it 'joins the project path onto the repository dir when set' do
      out, _err, status = run_main(full_env(tmpdir).merge('AC_REPOSITORY_DIR' => '/repo'))
      expect(status.exitstatus).to eq(0)
      expect(composed_command(out)).to include('-project "/repo/App.xcodeproj"')
    end

    it 'keeps an absolute project path unchanged' do
      out, _err, status = run_main(
        full_env(tmpdir).merge('AC_REPOSITORY_DIR' => '/repo',
                               'AC_PROJECT_PATH'   => '/elsewhere/App.xcodeproj')
      )
      expect(status.exitstatus).to eq(0)
      expect(composed_command(out)).to include('-project "/elsewhere/App.xcodeproj"')
    end
  end

  context 'AC_CONFIGURATION_NAME (optional)' do
    it 'omits -configuration when missing' do
      out, _err, status = run_main(full_env(tmpdir))
      expect(status.exitstatus).to eq(0)
      expect(composed_command(out)).not_to include('-configuration')
    end

    it 'passes the value through when set' do
      out, _err, status = run_main(full_env(tmpdir).merge('AC_CONFIGURATION_NAME' => 'Release'))
      expect(status.exitstatus).to eq(0)
      expect(composed_command(out)).to include('-configuration "Release"')
    end

    it 'omits -configuration for an empty string' do
      out, _err, status = run_main(full_env(tmpdir).merge('AC_CONFIGURATION_NAME' => ''))
      expect(status.exitstatus).to eq(0)
      expect(composed_command(out)).not_to include('-configuration')
    end
  end

  context 'AC_ARCHIVE_FLAGS (optional)' do
    it 'omits extra flags when missing' do
      out, _err, status = run_main(full_env(tmpdir))
      expect(status.exitstatus).to eq(0)
      expect(composed_command(out)).not_to include('-quiet')
    end

    it 'splits a pipe-separated value into separate flags' do
      out, _err, status = run_main(
        full_env(tmpdir).merge('AC_ARCHIVE_FLAGS' => '-quiet|-parallelizeTargets')
      )
      expect(status.exitstatus).to eq(0)
      cmd = composed_command(out)
      expect(cmd).to include('-quiet')
      expect(cmd).to include('-parallelizeTargets')
    end

    it 'keeps the extra flags in the order they were given' do
      out, _err, status = run_main(
        full_env(tmpdir).merge('AC_ARCHIVE_FLAGS' => '-quiet|-parallelizeTargets')
      )
      cmd = composed_command(out)
      expect(cmd.index('-quiet')).to be < cmd.index('-parallelizeTargets')
    end

    it 'omits extra flags for an empty string' do
      out, _err, status = run_main(full_env(tmpdir).merge('AC_ARCHIVE_FLAGS' => ''))
      expect(status.exitstatus).to eq(0)
      expect(composed_command(out)).not_to include('-quiet')
    end

    it 'passes a single flag through without a separator' do
      out, _err, status = run_main(full_env(tmpdir).merge('AC_ARCHIVE_FLAGS' => '-quiet'))
      expect(status.exitstatus).to eq(0)
      expect(composed_command(out)).to include('-quiet')
    end
  end
end

# ─── 5. xcodebuild command construction (subprocess – main.rb) ────────────────
RSpec.describe 'xcodebuild command construction' do
  let(:tmpdir) { Dir.mktmpdir('ios_test_cmd') }
  after { FileUtils.rm_rf(tmpdir) }

  def command_for(env = {})
    out, err, status = run_main(full_env(tmpdir).merge(env))
    expect(status.exitstatus).to eq(0), "stderr was: #{err}"
    composed_command(out)
  end

  context 'positive path – always-present flags' do
    it 'invokes xcodebuild' do
      expect(command_for).to start_with('xcodebuild ')
    end

    it 'quotes the scheme' do
      expect(command_for).to include('-scheme "MyScheme"')
    end

    it 'builds the destination from platform, device and OS version' do
      expect(command_for)
        .to include('-destination "platform=iOS Simulator,name=iPhone 15,OS=17.0"')
    end

    it 'points the result bundle at the output dir' do
      expect(command_for)
        .to include("-resultBundlePath \"#{File.join(tmpdir, 'output')}/test.xcresult\"")
    end

    it 'derives the derived-data path from the temporary path' do
      expect(command_for).to include("-derivedDataPath \"#{tmpdir}/Test/DerivedData\"")
    end

    it 'uses the test action' do
      expect(command_for).to include(' test')
    end

    it 'always passes COMPILER_INDEX_STORE_ENABLE' do
      expect(command_for).to include('COMPILER_INDEX_STORE_ENABLE=NO')
    end

    it 'passes COMPILER_INDEX_STORE_ENABLE=YES through unchanged' do
      expect(command_for('AC_COMPILER_INDEX_STORE_ENABLE' => 'YES'))
        .to include('COMPILER_INDEX_STORE_ENABLE=YES')
    end
  end

  context 'positive path – project type' do
    it 'passes -project for an .xcodeproj' do
      expect(command_for('AC_PROJECT_PATH' => 'App.xcodeproj'))
        .to include('-project "App.xcodeproj"')
    end

    it 'passes -workspace for an .xcworkspace' do
      expect(command_for('AC_PROJECT_PATH' => 'App.xcworkspace'))
        .to include('-workspace "App.xcworkspace"')
    end

    it 'does not pass -workspace for an .xcodeproj' do
      expect(command_for('AC_PROJECT_PATH' => 'App.xcodeproj')).not_to include('-workspace')
    end

    it 'does not pass -project for an .xcworkspace' do
      expect(command_for('AC_PROJECT_PATH' => 'App.xcworkspace')).not_to include('-project ')
    end
  end

  context 'positive path – combined optional flags' do
    it 'emits configuration, extra flags and the index-store flag together' do
      cmd = command_for(
        'AC_CONFIGURATION_NAME'          => 'Debug',
        'AC_ARCHIVE_FLAGS'               => '-quiet',
        'AC_COMPILER_INDEX_STORE_ENABLE' => 'YES'
      )
      expect(cmd).to include('-configuration "Debug"')
      expect(cmd).to include('-quiet')
      expect(cmd).to include('COMPILER_INDEX_STORE_ENABLE=YES')
    end
  end

  context 'negative path – values that need quoting' do
    it 'keeps a scheme containing spaces inside the quotes' do
      expect(command_for('AC_SCHEME' => 'My Scheme')).to include('-scheme "My Scheme"')
    end

    it 'keeps a project path containing spaces inside the quotes' do
      expect(command_for('AC_PROJECT_PATH' => 'My App.xcodeproj'))
        .to include('-project "My App.xcodeproj"')
    end

    it 'falls back to -project for a path with an unrecognised extension' do
      cmd = command_for('AC_PROJECT_PATH' => 'App.txt')
      expect(cmd).to include('-project "App.txt"')
      expect(cmd).not_to include('-workspace')
    end

    it 'falls back to -project for a path with no extension' do
      expect(command_for('AC_PROJECT_PATH' => 'App')).to include('-project "App"')
    end
  end
end

# ─── 6. Step failure (subprocess – main.rb) ───────────────────────────────────
RSpec.describe 'step failure' do
  let(:tmpdir) { Dir.mktmpdir('ios_test_fail') }
  after { FileUtils.rm_rf(tmpdir) }

  it 'exits non-zero when xcodebuild fails' do
    _out, _err, status = run_main(full_env(tmpdir), stub_source: XCODEBUILD_FAILING_STUB_SOURCE)
    expect(status.exitstatus).not_to eq(0)
  end

  it 'reports the exit code of the failed xcodebuild run' do
    _out, err, status = run_main(full_env(tmpdir), stub_source: XCODEBUILD_FAILING_STUB_SOURCE)
    expect(status.exitstatus).not_to eq(0)
    expect(err).to match(/Unexpected exit with code 65/)
  end

  it 'surfaces the captured stderr of the failed run' do
    out, _err, _status = run_main(full_env(tmpdir), stub_source: XCODEBUILD_FAILING_STUB_SOURCE)
    expect(out).to match(/stub-xcodebuild failure details/)
  end

  it 'has already written the env file before the test run starts' do
    env_file = File.join(tmpdir, 'env_file')
    run_main(full_env(tmpdir), stub_source: XCODEBUILD_FAILING_STUB_SOURCE)
    expect(File.read(env_file)).to include('AC_TEST_RESULT_PATH=')
  end

  it 'aborts when AC_TEMP_DIR is not a writable directory' do
    _out, err, status = run_main(
      full_env(tmpdir).merge('AC_TEMP_DIR' => File.join(tmpdir, 'no', 'such', 'dir'))
    )
    expect(status.exitstatus).not_to eq(0)
    expect(err).to match(/Unexpected exit with code/)
  end
end

# ─── 7. Loading main.rb as a library ──────────────────────────────────────────
RSpec.describe 'loading main.rb as a library' do
  it 'does not execute the step body when required' do
    out, _err, status = Open3.capture3(
      { 'AC_TEMP_DIR' => nil, 'AC_PROJECT_PATH' => nil, 'AC_SCHEME' => nil },
      RbConfig.ruby, '-e', "require '#{MAIN_RB}'; puts 'loaded'"
    )
    expect(status.exitstatus).to eq(0)
    expect(out).to include('loaded')
    expect(out).not_to include('@@[command]')
  end

  it 'defines every function under test' do
    out, _err, status = Open3.capture3(
      RbConfig.ruby, '-e',
      "require '#{MAIN_RB}'; " \
      "puts [:env_has_key, :run_command_simple, :abort_script].all? { |m| respond_to?(m, true) }"
    )
    expect(status.exitstatus).to eq(0)
    expect(out.strip).to eq('true')
  end
end

# ─── Coverage Report ──────────────────────────────────────────────────────────
def print_coverage_report
  return unless defined?(Coverage) && Coverage.running?

  result = begin
    Coverage.result(stop: false, clear: false)
  rescue ArgumentError
    Coverage.result
  end

  main_path = result.keys.find { |p| p&.end_with?('main.rb') }
  return puts("\nCoverage: main.rb not found in results") unless main_path

  data      = result[main_path]
  lines     = data.each_with_index.reject { |c, _| c.nil? }
  total     = lines.size
  covered   = lines.count { |c, _| c.to_i > 0 }
  pct       = total.positive? ? (covered * 100.0 / total).round(1) : 100.0
  uncovered = lines.select { |c, _| c.to_i == 0 }.map { |_, i| i + 1 }

  color = pct == 100 ? "\e[32;1m" : pct >= 80 ? "\e[33m" : "\e[31m"
  bar_filled = (pct / 5).round
  bar = "\e[32m" + '█' * bar_filled + "\e[90m" + '░' * (20 - bar_filled) + "\e[0m"

  puts "\n\e[90m#{'═' * 72}\e[0m"
  puts '  Coverage Report'
  puts "\e[90m#{'─' * 72}\e[0m"
  puts "  main.rb  #{bar}  #{color}#{pct}%\e[0m  (#{covered}/#{total} lines)"
  if uncovered.any? && uncovered.size <= 20
    puts "  Uncovered lines: \e[90m#{uncovered.join(', ')}\e[0m"
  elsif uncovered.any?
    puts "  Uncovered lines: \e[90m#{uncovered.first(15).join(', ')} … (+#{uncovered.size - 15} more)\e[0m"
  end
  puts "\e[90m#{'═' * 72}\e[0m"
end

# ─── Runner ───────────────────────────────────────────────────────────────────
if __FILE__ == $PROGRAM_NAME
  RSpec.configure do |config|
    config.add_formatter ReadableFormatter
    config.color = true
    config.order = :defined
  end

  exit_code = RSpec::Core::Runner.run(['--order', 'defined'])
  print_coverage_report
  exit exit_code
end
