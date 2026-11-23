import Foundation

public enum AppLanguage: String, CaseIterable {
    case system
    case simplifiedChinese = "zh-Hans"
    case english = "en"

    public func resolved(preferredLanguages: [String] = Locale.preferredLanguages) -> AppLanguage {
        guard self == .system else { return self }
        return preferredLanguages.first?.lowercased().hasPrefix("zh") == true ? .simplifiedChinese : .english
    }

    public var locale: Locale {
        Locale(identifier: resolved() == .simplifiedChinese ? "zh_CN" : "en_US")
    }
}

public struct AppText {
    public let language: AppLanguage
    public init(language: AppLanguage) { self.language = language }

    public func callAsFunction(_ source: String) -> String {
        guard language.resolved() == .english else { return source }
        if let value = Self.english[source] { return value }
        for (prefix, translation) in Self.englishPrefixes where source.hasPrefix(prefix) {
            return translation + source.dropFirst(prefix.count)
        }
        return source
    }

    private static let englishPrefixes = [
        "无法打开合盖接口：": "Couldn't open the lid-control interface: "
    ]

    private static let english = [
        "正在连接兼容服务…": "Connecting to compatibility service…",
        "盖盖兼容组件": "LidLid Compatibility",
        "让合盖运行更可靠": "Reliable closed-lid sessions",
        "免费组件，由你在 macOS 中授权。仅在盖盖会话期间管理系统睡眠；开盖、退出或连接超时后恢复原设置。": "A free component approved by you in macOS. It manages system sleep during LidLid sessions and restores the original setting when you reopen the lid, quit, or the connection times out.",
        "请先安装并授权盖盖兼容组件": "Install and approve LidLid Compatibility first",
        "兼容组件已就绪": "Compatibility component ready",
        "请在系统设置中允许盖盖兼容组件": "Allow LidLid Compatibility in System Settings",
        "请先把兼容组件拖到应用程序文件夹": "Drag LidLid Compatibility to Applications first",
        "睡眠已恢复，可以移除兼容组件": "Sleep restored. You can remove the compatibility app.",
        "已取消兼容服务注册": "Compatibility service registration cancelled",
        "打开应用程序文件夹": "Open Applications",
        "安装兼容服务": "Install service",
        "打开系统设置": "Open System Settings",
        "刷新状态": "Refresh",
        "恢复睡眠并移除服务": "Restore sleep & remove service",
        "移除服务": "Remove service",
        "需要主动睡眠时，请先关闭盖盖。移除组件前，请先点“恢复睡眠并移除服务”。": "Turn LidLid off before choosing Sleep. Use Restore sleep & remove service before deleting this app.",
        "请更新盖盖兼容组件": "Update LidLid Compatibility",
        "兼容组件暂时不可用，请重新打开组件检查": "Compatibility component unavailable. Open it to check its status.",
        "兼容组件响应超时，请保持开盖并检查组件": "Compatibility component timed out. Keep the lid open and check the component.",
        "兼容组件正在恢复睡眠，请保持开盖": "Restoring sleep. Keep the lid open.",
        "兼容组件正在移除，请重新安装后再试": "Compatibility service is being removed. Reinstall it before trying again.",
        "兼容组件未能确认睡眠设置，请稍后重试": "Could not confirm sleep settings. Try again.",
        "兼容组件会话已结束，请重新开启": "Compatibility session ended. Turn LidLid on again.",
        "睡眠设置被其他程序更改，本次已结束": "Another app changed sleep settings. This session has ended.",
        "兼容组件恢复记录版本不匹配，请联系支持": "Recovery record version mismatch. Contact support.",
        "请保持开盖，确认电量、温度和显示器状态后重试": "Keep the lid open and check battery, temperature and displays before trying again.",
        "电量、温度或用户状态改变，本次已结束": "Battery, temperature or user changed. This session has ended.",
        "无法读取系统睡眠设置，请稍后重试": "Could not read system sleep settings. Try again.",
        "系统睡眠设置超时，请保持开盖并重试": "Sleep setting request timed out. Keep the lid open and try again.",
        "系统睡眠设置响应异常": "Unexpected sleep setting response",
        "系统拒绝兼容组件的睡眠设置": "macOS rejected the compatibility sleep setting",
        "兼容服务需要 macOS 管理员授权": "The compatibility service requires macOS administrator approval",
        "兼容组件恢复目录权限异常，请联系支持": "Recovery directory permissions are invalid. Contact support.",
        "无法读取兼容组件恢复记录": "Could not read the compatibility recovery record",
        "兼容组件恢复记录权限或格式异常，请联系支持": "Recovery record permissions or format are invalid. Contact support.",
        "无法保存兼容组件恢复记录": "Could not save the compatibility recovery record",
        "无法安全保存兼容组件恢复记录": "Could not safely save the compatibility recovery record",
        "无法清除兼容组件恢复记录": "Could not clear the compatibility recovery record",
        "其他程序正在接管睡眠，请先关闭它的防睡眠功能": "Another app controls sleep. Turn off its keep-awake feature first.",
        "找不到合盖控制接口": "Lid-control interface not found",
        "系统睡眠当前处于禁用状态，且无法连接兼容服务。可在终端运行恢复命令还原默认睡眠：": "System sleep is currently disabled and the compatibility service is unreachable. Run this command in Terminal to restore normal sleep:",
        "复制命令": "Copy command",
        "已复制": "Copied"
    ]
}
