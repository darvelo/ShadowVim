//
//  Copyright © 2023 Mickaël Menu
//
//  This program is free software: you can redistribute it and/or modify
//  it under the terms of the GNU General Public License as published by
//  the Free Software Foundation, either version 3 of the License, or
//  (at your option) any later version.
//
//  This program is distributed in the hope that it will be useful,
//  but WITHOUT ANY WARRANTY; without even the implied warranty of
//  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
//  GNU General Public License for more details.
//
//  You should have received a copy of the GNU General Public License
//  along with this program.  If not, see <http://www.gnu.org/licenses/>.
//

import Combine
import Foundation
import Toolkit

public protocol NvimProcessDelegate: AnyObject {
    func nvimProcess(_ nvimProcess: NvimProcess, didTerminateWithStatus status: Int)
}

public final class NvimProcess {
    /// Starts a new Nvim process.
    public static func start(
        executableURL: URL = URL(fileURLWithPath: "/usr/bin/env"),
        logger: Logger?
    ) throws -> NvimProcess {
        let input = Pipe()
        let output = Pipe()
        let process = Process()
        process.executableURL = executableURL
        process.arguments = [
            "nvim",
            "--headless",
            "--embed",
            "-n", // Ignore swap files.
            "--clean", // Don't load default config and plugins.
            "-u", configURL().path,
        ]
        process.standardInput = input
        process.standardOutput = output
        process.environment = [
            "PATH": "$PATH:$HOME/bin"
                // MacPorts: https://guide.macports.org/#installing.shell.postflight
                + ":/usr/local/bin"
                // Homebrew: https://docs.brew.sh/FAQ#why-should-i-install-homebrew-in-the-default-location
                + ":/opt/homebrew/bin:/opt/local/bin"
                // XDG: https://specifications.freedesktop.org/basedir-spec/basedir-spec-latest.html
                + ":$HOME/.local/bin",
        ]

        try process.run()

        return NvimProcess(
            process: process,
            input: input.fileHandleForWriting,
            output: output.fileHandleForReading
        )
    }

    /// Locates ShadowVim's default configuration file.
    ///
    /// Precedence:
    ///   1. $XDG_CONFIG_HOME/svim/init.vim
    ///   2. $XDG_CONFIG_HOME/svim/init.lua
    ///   3. ~/.config/svim/init.vim
    ///   4. ~/.config/svim/init.lua
    ///
    /// See https://specifications.freedesktop.org/basedir-spec/basedir-spec-latest.html
    private static func configURL() -> URL {
        var configDir = ProcessInfo.processInfo
            .environment["XDG_CONFIG_HOME"] ?? "~/.config"
        configDir = NSString(string: configDir).expandingTildeInPath

        let configBase = URL(fileURLWithPath: configDir, isDirectory: true)
            .appendingPathComponent("svim/init", isDirectory: false)
        let vimlConfig = configBase.appendingPathExtension("vim")
        let luaConfig = configBase.appendingPathExtension("lua")

        return ((try? vimlConfig.checkResourceIsReachable()) ?? false)
            ? vimlConfig
            : luaConfig
    }

    public let process: Process
    public let input: FileHandle
    public let output: FileHandle
    public weak var delegate: NvimProcessDelegate?

    private var isRunning: Bool = true

    public init(
        process: Process,
        input: FileHandle,
        output: FileHandle
    ) {
        self.process = process
        self.input = input
        self.output = output

        process.terminationHandler = { [unowned self] _ in didTerminate() }

        // FIXME: To catch :q?
//        DispatchQueue.global().async {
//            process.waitUntilExit()
//            nvim.stop()
//            logger?.w("Nvim closed with status \(process.terminationStatus)")
//            nvim.delegate?.nvim(nvim, didFailWithError: .processStopped(status: Int(process.terminationStatus)))
//        }
    }

    deinit {
        stop()
    }

    /// Stops the Nvim process.
    public func stop() {
        guard isRunning else {
            return
        }
        if process.isRunning {
            process.interrupt()
        }
        didTerminate()
    }

    private func didTerminate() {
        guard isRunning else {
            return
        }
        isRunning = false
        delegate?.nvimProcess(self, didTerminateWithStatus: Int(process.terminationStatus))
    }
}