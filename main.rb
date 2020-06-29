# Instal dependencies
require 'open3'
require 'pathname'

# Check & validate Enviroment Variables
def env_has_key(key)
  return (ENV[key] != nil && ENV[key] !="") ? ENV[key] : abort("Missing #{key}.")
end

$temporary_path = env_has_key("AC_TEMP_DIR")
$project_path = ENV["AC_PROJECT_PATH"] || abort('Missing AC_PROJECT_PATH.')
$repository_path = ENV["AC_REPOSITORY_DIR"]
$project_full_path = $repository_path ? (Pathname.new $repository_path).join($project_path) : $project_path
$scheme = env_has_key("AC_SCHEME")
$output_path = env_has_key("AC_OUTPUT_DIR_PATH")
$test_result_path = "#{$output_path}/test.xcresult"

$test_os_version = env_has_key("AC_TEST_OS_VERSION")
$test_device = env_has_key("AC_TEST_DEVICE")
$test_platform = env_has_key("AC_TEST_PLATFORM")

$configuration_name = (ENV["AC_CONFIGURATION_NAME"] != nil && ENV["AC_CONFIGURATION_NAME"] !="") ? ENV["AC_CONFIGURATION_NAME"] : nil

$extra_options = []
if ENV["AC_ARCHIVE_FLAGS"] != "" && ENV["AC_ARCHIVE_FLAGS"] != nil
  $extra_options = ENV["AC_ARCHIVE_FLAGS"].split("|")
end

#compiler_index_store_enable - Options: YES, NO
$compiler_index_store_enable = env_has_key("AC_COMPILER_INDEX_STORE_ENABLE")

# Create a function to run test commands
def run_command(command, skip_abort)
  puts "@[command] #{command}"
  status = nil
  stdout_str = nil
  stderr_str = nil
  Open3.popen3(command) do |stdin, stdout, stderr, wait_thr|
    stdout.each_line do |line|
      puts line
    end
    stdout_str = stdout.read
    stderr_str = stderr.read
    status = wait_thr.value
  end
  unless status.success?
    puts stderr_str
    unless skip_abort
      exit 1
    end
  end
end

# Command to tell Xcode to run tests with parameters
command_xcodebuild_test = "xcodebuild -scheme \"#{$scheme}\" -destination \"platform=#{$test_platform},name=#{$test_device},OS=#{$test_os_version}\" -resultBundlePath \"#{$test_result_path}\" -derivedDataPath \"#{$temporary_path}/Test/DerivedData\" test"

if File.extname($project_path) == ".xcworkspace"
  command_xcodebuild_test.concat(" -workspace \"#{$project_full_path}\"")
else
  command_xcodebuild_test.concat(" -project \"#{$project_full_path}\"")
end

if $configuration_name != nil
  command_xcodebuild_test.concat(" ")
  command_xcodebuild_test.concat("-configuration \"#{$configuration_name}\"")
  command_xcodebuild_test.concat(" ")
end

if $extra_options.kind_of?(Array)
  $extra_options.each do |option|
    command_xcodebuild_test.concat(" ")
    command_xcodebuild_test.concat(option)
    command_xcodebuild_test.concat(" ")
  end
end

if $compiler_index_store_enable != nil
  command_xcodebuild_test.concat(" ")
  command_xcodebuild_test.concat("COMPILER_INDEX_STORE_ENABLE=#{$compiler_index_store_enable}")
  command_xcodebuild_test.concat(" ")
end
# Run our function and perform the tests
run_command(command_xcodebuild_test,false)

### Write Environment Variable
open(ENV['AC_ENV_FILE_PATH'], 'a') { |f|
  f.puts "AC_TEST_RESULT_PATH=#{$test_result_path}"
}

exit 0