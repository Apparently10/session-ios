// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

import UIKit

public typealias ThemeSettings = (theme: Theme?, primaryColor: Theme.PrimaryColor?, matchSystemNightModeSetting: Bool?)

public enum SNUIKit {
    public protocol ConfigType {
        var maxFileSize: UInt { get }
        var isStorageValid: Bool { get }
        
        func themeChanged(_ theme: Theme, _ primaryColor: Theme.PrimaryColor, _ matchSystemNightModeSetting: Bool)
        func navBarSessionIcon() -> NavBarSessionIcon
        func persistentTopBannerChanged(warningKey: String?)
        func cachedContextualActionInfo(tableViewHash: Int, sideKey: String) -> [Int: Any]?
        func cacheContextualActionInfo(tableViewHash: Int, sideKey: String, actionIndex: Int, actionInfo: Any)
        func removeCachedContextualActionInfo(tableViewHash: Int, keys: [String])
        func placeholderIconCacher(cacheKey: String, generator: @escaping () -> UIImage) -> UIImage
        func shouldShowStringKeys() -> Bool
    }
    
    private static var _mainWindow: UIWindow? = nil
    private static var _unsafeConfig: ConfigType? = nil
    
    /// The `mainWindow` of the application set during application startup
    ///
    /// **Note:** This should only be accessed on the main thread
    internal static var mainWindow: UIWindow? {
        assert(Thread.isMainThread)
        
        return _mainWindow
    }
    
    internal static var config: ConfigType? {
        switch Thread.isMainThread {
            case false:
                // Don't allow config access off the main thread
                print("SNUIKit Error: Attempted to access the 'SNUIKit.config' on the wrong thread")
                return nil
                
            case true: return _unsafeConfig
        }
    }
    
    public static func setMainWindow(_ mainWindow: UIWindow) {
        switch Thread.isMainThread {
            case true: _mainWindow = mainWindow
            case false: DispatchQueue.main.async { _mainWindow = mainWindow }
        }
    }
    
    public static func configure(with config: ConfigType, themeSettings: ThemeSettings?) {
        guard Thread.isMainThread else {
            return DispatchQueue.main.async {
                configure(with: config, themeSettings: themeSettings)
            }
        }
        
        // Apply the theme settings before storing the config so we don't needlessly update
        // the settings in the database
        ThemeManager.updateThemeState(
            theme: themeSettings?.theme,
            primaryColor: themeSettings?.primaryColor,
            matchSystemNightModeSetting: themeSettings?.matchSystemNightModeSetting
        )
        
        _unsafeConfig = config
    }
    
    internal static func themeSettingsChanged(
        _ theme: Theme,
        _ primaryColor: Theme.PrimaryColor,
        _ matchSystemNightModeSetting: Bool
    ) {
        guard Thread.isMainThread else {
            return DispatchQueue.main.async {
                themeSettingsChanged(theme, primaryColor, matchSystemNightModeSetting)
            }
        }
        
        config?.themeChanged(theme, primaryColor, matchSystemNightModeSetting)
    }
    
    internal static func navBarSessionIcon() -> NavBarSessionIcon {
        guard let config: ConfigType = self.config else { return NavBarSessionIcon() }
        
        return config.navBarSessionIcon()
    }
    
    internal static func topBannerChanged(to warning: TopBannerController.Warning?) {
        guard let warning: TopBannerController.Warning = warning else {
            config?.persistentTopBannerChanged(warningKey: nil)
            return
        }
        guard warning.shouldAppearOnResume else { return }
        
        config?.persistentTopBannerChanged(warningKey: warning.rawValue)
    }
    
    internal static func placeholderIconCacher(cacheKey: String, generator: @escaping () -> UIImage) -> UIImage {
        guard let config: ConfigType = self.config else { return generator() }
        
        return config.placeholderIconCacher(cacheKey: cacheKey, generator: generator)
    }
    
    public static func shouldShowStringKeys() -> Bool {
        guard let config: ConfigType = self.config else { return false }
        
        return config.shouldShowStringKeys()
    }
}
