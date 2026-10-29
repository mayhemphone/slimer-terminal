import Foundation

/// What Settings wants for one global action.
enum GlobalKeybindState: Equatable {
    /// Settings doesn't touch this action; whatever the user's config says applies.
    case unmanaged
    /// Bound to this trigger (recorder grammar).
    case set(String)
    /// No global hotkey: the user's own global bindings for it are unbound in the block.
    case disabled
}

/// Turns per-action ``GlobalKeybindState`` into `keybind` values for the managed block,
/// and back. Pure, so it can be tested without files.
///
/// The user's own `keybind = global:…=<action>` lines are never edited. When Settings sets
/// another trigger for that action (or disables it), the block *unbinds* the user's trigger
/// instead, which works because the block comes after those lines. Triggers outside the
/// recorder grammar can't be unbound safely and are reported back.
enum GlobalKeybindPlanner {
    struct UserBinding: Equatable {
        var line: Int
        var action: ManagedGlobalAction
        /// The trigger in canonical form (see ``KeybindValue/normalizedTrigger``).
        var trigger: String
        /// Whether the binding comes after the managed block (Settings can't override it).
        var afterBlock: Bool
        /// Another config file the binding is in (another default file or an include);
        /// nil for the file Settings edits. Settings never unbinds those.
        var file: String?

        init(line: Int, action: ManagedGlobalAction, trigger: String, afterBlock: Bool, file: String? = nil) {
            self.line = line
            self.action = action
            self.trigger = trigger
            self.afterBlock = afterBlock
            self.file = file
        }

        /// The trigger can be echoed into the block only when it is in the recorder grammar
        /// and the line comes before the block in the same file.
        var isUnbindable: Bool { file == nil && !afterBlock && KeyTrigger.isValid(trigger) }

        /// "line 3" or "~/.config/ghostty/extra line 3".
        var location: String {
            guard let file else { return "Line \(line) of your config" }
            return "\((file as NSString).abbreviatingWithTildeInPath) line \(line)"
        }
    }

    /// The user's `global:` bindings (outside the block) for the managed actions.
    static func userBindings(in text: String) throws -> [UserBinding] {
        try userBindings(lines: GhosttyConfigWriter.split(text))
    }

    static func userBindings(lines: GhosttyConfigWriter.Lines) throws -> [UserBinding] {
        let settings = try GhosttyConfigWriter.userSettings(lines: lines)
        return bindings(in: settings.before, afterBlock: false) + bindings(in: settings.after, afterBlock: true)
    }

    /// Global bindings of the managed actions among `settings`.
    static func bindings(
        in settings: [GhosttyConfigWriter.Setting],
        afterBlock: Bool,
        file: String? = nil
    ) -> [UserBinding] {
        settings.compactMap { setting in
            guard setting.key == "keybind",
                  let bind = KeybindValue(parsing: setting.value),
                  bind.prefixes.contains("global"),
                  let action = ManagedGlobalAction(rawValue: bind.action) else { return nil }
            return UserBinding(line: setting.line, action: action, trigger: bind.normalizedTrigger,
                               afterBlock: afterBlock, file: file)
        }
    }

    /// Reads the per-action state back from the block's `keybind` values.
    static func states(
        managedValues: [String],
        userBindings: [UserBinding]
    ) -> [ManagedGlobalAction: GlobalKeybindState] {
        var result: [ManagedGlobalAction: GlobalKeybindState] = [:]
        var unbound: Set<String> = []
        for value in managedValues {
            guard let bind = KeybindValue(parsing: value) else { continue }
            if bind.action == "unbind" {
                unbound.insert(bind.normalizedTrigger)
            } else if let action = ManagedGlobalAction(rawValue: bind.action), bind.prefixes == ["global"] {
                result[action] = .set(bind.normalizedTrigger)
            }
        }
        for binding in userBindings where result[binding.action] == nil && unbound.contains(binding.trigger) {
            result[binding.action] = .disabled
        }
        for action in ManagedGlobalAction.allCases where result[action] == nil {
            result[action] = .unmanaged
        }
        return result
    }

    struct Plan: Equatable {
        /// `keybind` values for the block: unbinds first, then bindings.
        var values: [String]
        /// User bindings that stay active because Settings can't unbind them.
        var leftActive: [UserBinding]
    }

    static func plan(
        states: [ManagedGlobalAction: GlobalKeybindState],
        userBindings: [UserBinding]
    ) -> Plan {
        var unbinds: [String] = []
        var binds: [String] = []
        var leftActive: [UserBinding] = []

        for action in ManagedGlobalAction.allCases {
            let state = states[action] ?? .unmanaged
            let wanted: String?
            switch state {
            case .unmanaged:
                continue
            case .set(let trigger):
                guard let value = action.keybindValue(trigger: trigger) else { continue }
                wanted = trigger
                binds.append(value)
            case .disabled:
                wanted = nil
            }
            for binding in userBindings where binding.action == action && binding.trigger != wanted {
                if binding.isUnbindable {
                    let value = "global:\(binding.trigger)=unbind"
                    if !unbinds.contains(value) { unbinds.append(value) }
                } else {
                    leftActive.append(binding)
                }
            }
        }

        // Never unbind a trigger that a binding in the block reuses (it is rebound anyway,
        // and the unbind would come first, so this only keeps the block tidy).
        let boundTriggers = Set(binds.compactMap { KeybindValue(parsing: $0)?.normalizedTrigger })
        unbinds.removeAll { value in
            KeybindValue(parsing: value).map { boundTriggers.contains($0.normalizedTrigger) } ?? false
        }
        return Plan(values: unbinds + binds, leftActive: leftActive)
    }
}
