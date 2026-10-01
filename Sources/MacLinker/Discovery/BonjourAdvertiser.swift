import Foundation
import Network

enum BonjourAdvertiser {
    static func service(name: String, deviceID: String) -> NWListener.Service {
        NWListener.Service(name: name, type: K.serviceType,
                           txtRecord: NWTXTRecord(["id": deviceID, "v": "\(K.protocolVersion)"]))
    }
}
