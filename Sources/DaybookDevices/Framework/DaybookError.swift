import DaybookCore

/// `DaybookError` moved to DaybookCore, beside the store that throws most of them; device code and
/// anything importing only DaybookDevices keep this name for it.
public typealias DaybookError = DaybookCore.DaybookError
