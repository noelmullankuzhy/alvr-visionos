//
//  ViewModel.swift
//  ALVRClient
//

import SwiftUI

@Observable
class ViewModel {
    // Client
    var isShowingClient: Bool = false
    var offlineDiagnostics = OfflineDiagnosticsLifecycle()
    var isShowingDiagnosticsOffline: Bool { offlineDiagnostics.ownsSpace }

}
