import SwiftUI

struct ContentView: View {
    @ObservedObject private var bt = BluetoothManager.shared

    var body: some View {
        NavigationView {
            ScrollView {
                VStack(spacing: 16) {

                    // ─── 1. 연결 상태 카드 ────────────────────────────
                    statusCard

                    // ─── 2. 등록된 기기 / 연결 해제 ──────────────────
                    if let name = bt.connectedDeviceName ?? bt.savedDeviceName {
                        registeredDeviceCard(name: name)
                    }

                    // ─── 3. 스캔 버튼 ─────────────────────────────────
                    scanButton

                    // ─── 4. 발견된 기기 목록 ─────────────────────────
                    if bt.isScanning || !bt.discoveredDevices.isEmpty {
                        deviceList
                    }

                    // ─── 5. 디버그 로그 ───────────────────────────────
                    debugLog
                }
                .padding(.vertical, 12)
            }
            .navigationTitle("BLE Auto Connect")
            .onAppear { bt.setup() }
        }
    }

    // MARK: - 연결 상태 카드

    private var statusCard: some View {
        VStack(spacing: 10) {
            // 상태 아이콘
            Group {
                if bt.connectedDeviceName != nil {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundColor(.green)
                } else if bt.isScanning {
                    ProgressView()
                        .scaleEffect(1.3)
                } else {
                    Image(systemName: "antenna.radiowaves.left.and.right.slash")
                        .foregroundColor(.secondary)
                }
            }
            .font(.system(size: 42))
            .frame(height: 50)

            Text(bt.connectionStatus)
                .font(.headline)
                .foregroundColor(statusColor)
                .multilineTextAlignment(.center)
                .padding(.horizontal)

            // HW 블루투스 상태 표시
            HStack(spacing: 6) {
                Circle()
                    .fill(bt.isBluetoothOn ? Color.green : Color.red)
                    .frame(width: 8, height: 8)
                Text("HW 블루투스: \(bt.bluetoothStateString)")
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }

            if bt.bluetoothStateString.contains("Initial") || bt.bluetoothStateString.contains("Unknown") {
                Button("수동 초기화 (Force Reset)") { bt.forceReset() }
                    .font(.caption)
                    .foregroundColor(.blue)
            }
        }
        .padding()
        .frame(maxWidth: .infinity)
        .background(Color(.systemGray6))
        .cornerRadius(12)
        .padding(.horizontal)
    }

    // MARK: - 등록된 기기 카드

    private func registeredDeviceCard(name: String) -> some View {
        HStack(spacing: 14) {
            Image(systemName: "applewatch")
                .font(.title)
                .foregroundColor(.blue)

            VStack(alignment: .leading, spacing: 3) {
                Text(name)
                    .font(.body).bold()
                Text(bt.connectedDeviceName != nil ? "연결됨" : "범위 내 진입 시 자동 연결")
                    .font(.caption)
                    .foregroundColor(bt.connectedDeviceName != nil ? .green : .secondary)
            }

            Spacer()

            Button(action: { bt.disconnect() }) {
                Text("해제")
                    .font(.footnote).bold()
                    .foregroundColor(.red)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(Color.red.opacity(0.1))
                    .cornerRadius(8)
            }
        }
        .padding()
        .background(Color.blue.opacity(0.06))
        .cornerRadius(12)
        .padding(.horizontal)
    }

    // MARK: - 스캔 버튼

    private var scanButton: some View {
        Button(action: {
            if bt.isScanning { bt.stopScanning() }
            else { bt.startScanning() }
        }) {
            HStack {
                Image(systemName: bt.isScanning ? "stop.circle.fill" : "magnifyingglass")
                Text(bt.isScanning
                     ? "검색 중지"
                     : (bt.savedDeviceName == nil ? "주변 기기 검색" : "다른 기기 검색"))
            }
            .font(.headline)
            .foregroundColor(.white)
            .padding()
            .frame(maxWidth: .infinity)
            .background(bt.isBluetoothOn
                        ? (bt.isScanning ? Color.orange : Color.blue)
                        : Color.gray)
            .cornerRadius(12)
        }
        .disabled(!bt.isBluetoothOn)
        .padding(.horizontal)
    }

    // MARK: - 발견된 기기 목록

    private var deviceList: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("발견된 기기")
                    .font(.subheadline).bold()
                if bt.isScanning {
                    ProgressView().scaleEffect(0.8)
                }
                Spacer()
                Text("\(bt.discoveredDevices.count)개")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            .padding(.horizontal)

            if bt.discoveredDevices.isEmpty {
                Text("주변 기기를 찾는 중...")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity)
                    .padding()
            } else {
                VStack(spacing: 0) {
                    ForEach(bt.discoveredDevices) { device in
                        Button(action: { bt.selectDevice(device) }) {
                            HStack(spacing: 14) {
                                // 신호 강도 아이콘
                                Image(systemName: rssiIcon(device.rssi))
                                    .foregroundColor(rssiColor(device.rssi))
                                    .frame(width: 28)

                                VStack(alignment: .leading, spacing: 3) {
                                    Text(device.name)
                                        .font(.body).bold()
                                        .foregroundColor(.primary)
                                    Text("신호 강도: \(device.rssi) dBm")
                                        .font(.caption2)
                                        .foregroundColor(.secondary)
                                }

                                Spacer()

                                Text("연결")
                                    .font(.footnote).bold()
                                    .foregroundColor(.white)
                                    .padding(.horizontal, 14)
                                    .padding(.vertical, 7)
                                    .background(Color.blue)
                                    .cornerRadius(8)
                            }
                            .padding(.horizontal, 16)
                            .padding(.vertical, 12)
                        }
                        Divider().padding(.leading, 56)
                    }
                }
                .background(Color(.systemBackground))
                .cornerRadius(12)
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(Color(.systemGray4), lineWidth: 0.5)
                )
                .padding(.horizontal)
            }
        }
    }

    // MARK: - 디버그 로그

    private var debugLog: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("디버그 로그", systemImage: "terminal")
                .font(.caption).bold()
                .foregroundColor(.secondary)

            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(Array(bt.logMessages.enumerated()), id: \.offset) { idx, msg in
                            Text(msg)
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundColor(.secondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .id(idx)
                        }
                    }
                }
                .frame(height: 120)
                .onChange(of: bt.logMessages.count) { _, _ in
                    if let last = bt.logMessages.indices.last {
                        proxy.scrollTo(last, anchor: .bottom)
                    }
                }
            }
            .padding(8)
            .background(Color(.systemGray6))
            .cornerRadius(8)
        }
        .padding(.horizontal)
        .padding(.bottom, 10)
    }

    // MARK: - Helpers

    private var statusColor: Color {
        let s = bt.connectionStatus
        if s.contains("연결됨") || s.contains("✅") { return .green }
        if s.contains("중") || s.contains("대기") || s.contains("복원") { return .orange }
        return .red
    }

    private func rssiIcon(_ rssi: Int) -> String {
        switch rssi {
        case -60...:   return "wifi"
        case -75..<(-60): return "wifi"
        case -90..<(-75): return "wifi"
        default:       return "wifi.slash"
        }
    }

    private func rssiColor(_ rssi: Int) -> Color {
        switch rssi {
        case -60...:      return .green
        case -75..<(-60): return .orange
        default:          return .red
        }
    }
}
