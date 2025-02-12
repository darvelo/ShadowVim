# Changelog

All notable changes to this project will be documented in this file.

## [Unreleased]

### Fixed

* [#50](https://github.com/mickael-menu/ShadowVim/issues/50) Fix issue where the cursor position is not updated when using third-party plugins like `chaoren/vim-wordmotion`.


## [0.2.0]

### Added

* Support for Visual and Select modes feedback.
    * Block-wise selection (<kbd>C-v</kbd>) is displayed as character-wise because of a limitation with the Xcode accessibility APIs.
* Open a Neovim terminal TUI for the embedded instance (requires Neovim 0.9).
    * This is useful to solve blocking prompts in Neovim, for instance.
    * Activate from the status menu, or manually with:
        ```sh
        nvim --server /tmp/shadowvim.pipe --remote-ui
        ```
* Use `SVPress` to trigger click events from Neovim bindings.
    ```viml
    " Show the Quick Help pop-up for the symbol at the caret location (<kbd>⌥ + Left Click</kbd>).
    nmap K <Cmd>SVPress <LT>M-LeftMouse><CR>

    " Perform a right click at the caret location.
    nmap gR <Cmd>SVPress <LT>RightMouse><CR>
    ```
* Use `SVSetInputUI` to let Xcode handle all key events.
* Use `SVSetInputNvim` to forward key events to Neovim, even in Insert mode.
* Use `SVOpenTUI` to launch a Terminal window with a Neovim text user interface of the embedded Neovim instance.
    * This is useful to solve issues with Neovim such as a blocking prompt.

### Deprecated

* `SVEnableKeysPassthrough` is deprecated in favor of the new `SVSetInputUI` command.

### Changed

* The Insert mode is now handled by Xcode to improve performance, auto-completion and indentation.
    * ShadowVim does not need to override your Xcode editing settings anymore.
    * Unfortunately, that means that Neovim Insert features are unavailable (e.g. `iab` abbreviations or `imap` mappings).
* `SVPressKeys` was renamed to `SVPress`.
* `SVPress` now emits the keyboard shortcut system-wide instead of only in the Xcode process.
    * This can be used to have a custom passthrough for hot keys (e.g. <kbd>⌥\`</kbd> to open iTerm) by adding this to your `init.vim`:
    ```viml
    if exists('g:shadowvim')
        map <A-`> <Cmd>SVPressKeys <LT>A-`><CR>
    endif
    ```
* The system paste shortcut (<kbd>⌘V</kbd>) is now overridden and handled by Neovim to improve performances and the undo history.

### Fixed

* Significantly improve performance when applying changes from Neovim.


## [0.1.1]

### Added

* Xcode's settings are automatically updated to prevent conflicts when running ShadowVim.
    * The user is prompted with a bunch of terminal commands reverting the changes.

### Fixed

* Fix **Quit** and **Reset** buttons in the error dialogs.
* Fix synchronizing buffers with extra newlines at the end.
* Fix activating ShadowVim when restarting Xcode.
* Improve handling of some AX errors.

## [0.1]

### Added

* Basic Neovim / UI buffer and cursor synchronization.
* Support for **Normal**, **Insert** and **Replace** modes.
* Neovim user commands to trigger UI keyboard shortcuts.

[unreleased]: https://github.com/mickael-menu/ShadowVim/compare/main...HEAD
[0.2.0]: https://github.com/mickael-menu/ShadowVim/compare/0.1.1...0.2.0
[0.1.1]: https://github.com/mickael-menu/ShadowVim/compare/0.1.0...0.1.1
[0.1]: https://github.com/mickael-menu/ShadowVim/tree/0.1.0
