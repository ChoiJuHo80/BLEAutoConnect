import SwiftUI

struct ContentView: View {
    @ObservedObject private var bt = BluetoothManager.shared

    var body: some View {
        NavigationView {
            ScrollView {
                VStack(spacing: 16) {
                    statusCard
                    registeredDeviceCard
                    scanButton
                    if bt.isScanning || !bt.discoveredDevices.isEmpty {
                        deviceList
                    }
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
                } else if bt.connectionStatus.contains("중") || bt.connectionStatus.contains("대기") || bt.connectionStatus.contains("재연결") {
                    ProgressView().scaleEffect(1.3)
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
                    .font(.caption).foregroundColor(.blue)
            }
        }
        .padding()
        .frame(maxWidth: .infinity)
        .background(Color(.systemGray6))
        .cornerRadius(12)
        .padding(.horizontal)
    }

    // MARK: - 등록된 기기 카드

    @ViewBuilder
    private var registeredDeviceCard: some View {
        if let name = bt.connectedDeviceName ?? bt.savedDeviceName {
            HStack(spacing: 14) {
                ZStack {
                    Circle()
                        .fill(bt.connectedDeviceName != nil ? Color.green.opacity(0.15) : Color.blue.opacity(0.1))
                        .frame(width: 48, height: 48)
                    Image(systemName: "applewatch")
                        .font(.title2)
                        .foregroundColor(bt.connectedDeviceName != nil ? .green : .blue)
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text(name)
                        .font(.body).bold()
                    HStack(spacing: 4) {
                        Circle()
                            .fill(bt.connectedDeviceName != nil ? Color.green : Color.orange)
                            .frame(width: 6, height: 6)
                        Text(bt.connectedDeviceName != nil
                             ? "연결됨 (BLE)"
                             : "자동 재연결 대기 중")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
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
            .background(Color(.systemBackground))
            .cornerRadius(12)
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(bt.connectedDeviceName != nil ? Color.green.opacity(0.4) : Color.blue.opacity(0.2), lineWidth: 1)
            )
            .padding(.horizontal)
        }
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
                     : (bt.savedDeviceName == nil ? "주변 기기 검색" : "다른 기기로 변경"))
            }
            .font(.headline)
            .foregroundColor(.white)
            .padding()
            .frame(maxWidth: .infinity)
            .background(
                bt.isBluetoothOn
                    ? (bt.isScanning ? Color.orange : Color.blue)
                    : Color.gray
            )
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
                if bt.isScanning { ProgressView().scaleEffect(0.8) }
                Spacer()
                Text("\(bt.discoveredDevices.count)개")
                    .font(.caption).foregroundColor(.secondary)
            }
            .padding(.horizontal)

            if bt.discoveredDevices.isEmpty {
                Text(bt.isScanning ? "주변 기기를 찾는 중..." : "발견된 기기가 없습니다.")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity)
                    .padding()
            } else {
                VStack(spacing: 0) {
                    ForEach(bt.discoveredDevices) { device in
                        Button(action: { bt.selectDevice(device) }) {
                            HStack(spacing: 14) {
                                // 신호 강도 시각화
                                VStack(spacing: 1) {
                                    ForEach([0, 1, 2], id: \.self) { i in
                                        RoundedRectangle(cornerRadius: 1)
                                            .fill(signalBarColor(rssi: device.rssi, bar: i))
                                            .frame(width: 4, height: CGFloat(4 + i * 4))
                                    }
                                }
                                .frame(width: 20, height: 20, alignment: .bottom)

                                VStack(alignment: .leading, spacing: 3) {
                                    Text(device.name)
                                        .font(.body).bold()
                                        .foregroundColor(.primary)
                                    Text("\(device.rssi) dBm · \(signalLabel(device.rssi))")
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
                        Divider().padding(.leading, 52)
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
                .frame(height: 130)
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
        if s.contains("✅") || s.contains("연결됨") { return .green }
        if s.contains("중") || s.contains("대기") || s.contains("재연결") { return .orange }
        return .red
    }

    private func signalBarColor(rssi: Int, bar: Int) -> Color {
        let thresholds = [-75, -65, -50]
        return rssi >= thresholds[bar] ? .blue : Color(.systemGray4)
    }

    private func signalLabel(_ rssi: Int) -> String {
        if rssi >= -50 { return "매우 강함" }
        if rssi >= -65 { return "강함" }
        if rssi >= -75 { return "보통" }
        return "약함"
    }
}
