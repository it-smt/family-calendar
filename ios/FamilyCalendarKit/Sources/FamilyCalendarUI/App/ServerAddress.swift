import Foundation

/// Where the app finds the server. One value, because there is one deployment
/// and two people using it.
///
/// Not called `Configuration`: GRDB has a type by that name, and any file that
/// imports both would mean the wrong one.
public enum ServerAddress {
    /// `localhost` works from the simulator, which shares the Mac's network.
    /// On a real device, set this to the Mac's address on the network and give
    /// App Transport Security an exception for it — see ios/SETUP.md.
    public nonisolated(unsafe) static var url = URL(string: "http://localhost:8000")!
}
