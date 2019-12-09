
public extension Notification.Name {
    public static let contactOnlineStatusChanged = Notification.Name("contactOnlineStatusChanged")
    public static let newMessagesReceived = Notification.Name("newMessagesReceived")
    public static let threadFriendRequestStatusChanged = Notification.Name("threadFriendRequestStatusChanged")
    public static let messageFriendRequestStatusChanged = Notification.Name("messageFriendRequestStatusChanged")
    public static let threadDeleted = Notification.Name("threadDeleted")
    public static let dataNukeRequested = Notification.Name("dataNukeRequested")
    public static let threadSessionRestoreDevicesChanged = Notification.Name("threadSessionRestoreDevicesChanged")
}

@objc public extension NSNotification {
    @objc public static let contactOnlineStatusChanged = Notification.Name.contactOnlineStatusChanged.rawValue as NSString
    @objc public static let newMessagesReceived = Notification.Name.newMessagesReceived.rawValue as NSString
    @objc public static let threadFriendRequestStatusChanged = Notification.Name.threadFriendRequestStatusChanged.rawValue as NSString
    @objc public static let messageFriendRequestStatusChanged = Notification.Name.messageFriendRequestStatusChanged.rawValue as NSString
    @objc public static let threadDeleted = Notification.Name.threadDeleted.rawValue as NSString
    @objc public static let dataNukeRequested = Notification.Name.dataNukeRequested.rawValue as NSString
    @objc public static let threadSessionRestoreDevicesChanged = Notification.Name.threadSessionRestoreDevicesChanged.rawValue as NSString
}
