/// An error that means the work is gone with no observer: a transport dropped under an in-flight request. The run plane reports it as ``OperationOutcome/lost``.
public protocol LostRunError: Error {}
