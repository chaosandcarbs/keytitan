KeyTitan iOS Credential Provider
================================

These files are the source scaffold for an iOS AutoFill Credential Provider
extension. The target is added to `Runner.xcodeproj`, but it still needs to be
opened on macOS/Xcode and signed with the correct App Group entitlement for your
Apple developer team.

The extension intentionally does not persist or return credentials yet. iOS
AutoFill runs in an app extension process, so it will need an App Group backed
shared store and an unlock/selection flow before it can safely provide vault
items.

The Runner app registers non-secret credential identities with
`ASCredentialIdentityStore` when the vault is open and autofill is selected.
Plaintext passwords are not written into the shared extension scaffold.
