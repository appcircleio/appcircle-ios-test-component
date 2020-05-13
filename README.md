# Appcircle Xcodebuild For Test

Appcircle helps you perform unit and UI tests for your iOS applications at once.
Unit tests usually test a piece of your code and confirm the code behaves as expected in certain conditions.

Required Input Variables
- `$AC_SCHEME`: Specifies the project scheme for build.
- `$AC_PROJECT_PATH`: Specifies the project path. For example : ./appcircle.xcodeproj.
- `$AC_TEST_OS_VERSION`: Specifies os version for test.
- `$AC_TEST_DEVICE`: Specifies device for test.
- `$AC_TEST_PLATFORM`: Specifies platform for test.

Optional Input Variables
- `$AC_REPOSITORY_DIR`: Specifies the cloned repository directory.
- `$AC_ARCHIVE_FLAGS`: Specifies the extra xcodebuild flag. For example : -configuration DEBUG
- `$AC_CONFIGURATION_NAME`: The configuration to use. You can overwrite it with this option.
- `$AC_COMPILER_INDEX_STORE_ENABLE`: You can disable the indexing during the build for faster build.

Output Variables
- `$AC_TEST_RESULT_PATH`: Test result path.
