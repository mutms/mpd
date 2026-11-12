# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## Unreleased

### Added

- `MPD_MOODLE_BEHAT_HEADLESS=1` runs Behat's Chromium headless, so parallel
  Behat runs no longer lose focus events. Off by default, to keep the
  browsers visible in the selenium web view.
