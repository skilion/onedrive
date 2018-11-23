# Changelog

The format is based on [Keep a Changelog](http://keepachangelog.com/en/1.0.0/)
and this project adheres to [Semantic Versioning](http://semver.org/spec/v2.0.0.html).

## [1.1.3] - 2018-09-09
### Fixed
- Excessive usage of CPU in monitor mode

## [1.1.2] - 2018-09-09
### Added
- Test suite
### Changed
- Disabled buffering on stdout
### Fixed
- Crash when the delta link is expired
- Crash when an item is deleted

## [1.1.1] - 2018-01-20
### Fixed
- Wrong regex for parsing authentication uri

## [1.1.0] - 2018-01-19
### Added
- Support for shared folders (OneDrive Personal only)
- `--download` option to only download changes
- `DC` variable in Makefile to chose the compiler
### Changed
- Print logs on stdout instead of stderr
- Improve log messages

## [1.0.1] - 2017-08-01
### Added
- `--syncdir` option
### Changed
- `--version` output simplified
- Updated README
### Fixed
- Fix crash caused by remotely deleted and recreated directories

## [1.0.0] - 2017-07-14
### Added
- `--version` option
