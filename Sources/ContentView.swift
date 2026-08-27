import SwiftUI

struct ContentView: View {
    @ObservedObject private var bt = BluetoothManager.shared

    /// 이름 설정 편집 중 여부
    @State private var isEditingName = false
    /// TextField 임시 값
    @State private var editingText = ""

    var body: some View {
        NavigationView {
            ScrollView {
                VStack(spacing: 16) {

                    // ─── 1. 대상 기기 이름 설정 ───────────────────────
                    targetNameSection

                    // ─── 2. 연결 상태 ────────────────────────────────
                    connectionStatusSection

                    // ─── 3. 스캔 / 연결 해제 버튼 ────────────────────
                    actionButtons

                    // ─── 4. 디버그 로그 ───────────────────────────────
                    debugLogSection
                }
                .padding(.vertical, 12)
            }
            .navigationTitle("BLE Auto Connect")
            .onAppear {
                bt.setup()
            }
        }
    }

    // MARK: - 대상 기기 이름 설정

    private var targetNameSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("연결할 기기 이름 설정", systemImage: "pencil.circle.fill")
                .font(.subheadline).bold()

            if isEditingName {
                HStack {
                    TextField("예: Galaxy Watch6", text: $editingText)
                        .textFieldStyle(.roundedBorder)
                        .autocorrectionDisabled()
                        .submitLabel(.done)
                        .onSubmit { saveTargetName() }

                    Button("저장") { saveTargetName() }
                        .buttonStyle(.borderedProminent)
                        .tint(.blue)
                }
            } else {
                HStack {
                    if bt.targetDeviceName.trimmingCharacters(in: .whitespaces).isEmpty {
                        Text("설정된 기기 없음")
                            .foregroundColor(.secondary)
                            .italic()
                    } else {
                        Label(bt.targetDeviceName, systemImage: "applewatch")
                            .font(.body).bold()
                            .foregroundColor(.primary)
                    }
                    Spacer()
                    Button("변경") {
                        editingText = bt.targetDeviceName
                        isEditingName = true
                    }
                    .font(.footnote)
                    .foregroundColor(.blue)
                }
            }

            if !bt.targetDeviceName.trimmingCharacters(in: .whitespaces).isEmpty {
                Text("이 이름을 포함한 기기가 발견되면 자동으로 연결됩니다.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .padding()
        .background(Color(.systemGray6))
        .cornerRadius(12)
        .padding(.horizontal)
    }

    // MARK: - 연결 상태

    private var connectionStatusSection: some View {
        VStack(spacing: 10) {
            // 연결됨 아이콘
            if bt.connectedDeviceName != nil {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 44))
                    .foregroundColor(.green)
            } else if bt.isScanning {
                ProgressView()
                    .scaleEffect(1.4)
                    .padding(.bottom, 4)
            } else {
                Image(systemName: "antenna.radiowaves.left.and.right.slash")
                    .font(.system(size: 44))
                    .foregroundColor(.secondary)
            }

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

            // Force Reset 버튼
            if bt.bluetoothStateString.contains("Initial") || bt.bluetoothStateString.contains("Unknown") {
                Button("수동 초기화 (Force Reset)") {
                    bt.forceReset()
                }
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

    // MARK: - 액션 버튼

    private var actionButtons: some View {
        VStack(spacing: 10) {
            // 스캔 시작 / 중지
            Button(action: {
                if bt.isScanning {
                    bt.stopScanning()
                } else {
                    bt.startScanning()
                }
            }) {
                HStack {
                    Image(systemName: bt.isScanning ? "stop.circle.fill" : "magnifyingglass")
                    Text(scanButtonLabel)
                }
                .font(.headline)
                .foregroundColor(.white)
                .padding()
                .frame(maxWidth: .infinity)
                .background(scanButtonColor)
                .cornerRadius(12)
            }
            .disabled(!bt.isBluetoothOn)
            .padding(.horizontal)

            // 연결 해제 버튼 (연결됐을 때만)
            if bt.connectedDeviceName != nil {
                Button(action: { bt.disconnect() }) {
                    HStack {
                        Image(systemName: "xmark.circle.fill")
                        Text("연결 해제")
                    }
                    .font(.headline)
                    .foregroundColor(.white)
                    .padding()
                    .frame(maxWidth: .infinity)
                    .background(Color.red)
                    .cornerRadius(12)
                }
                .padding(.horizontal)
            }
        }
    }

    // MARK: - 디버그 로그

    private var debugLogSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("실시간 디버그 로그", systemImage: "magnifyingglass")
                .font(.caption).bold()
                .foregroundColor(.gray)

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

    private func saveTargetName() {
        let name = editingText.trimmingCharacters(in: .whitespaces)
        bt.targetDeviceName = name
        UserDefaults.standard.set(name, forKey: "TargetDeviceName")
        isEditingName = false
    }

    private var scanButtonLabel: String {
        if bt.isScanning {
            return "검색 중지"
        }
        let name = bt.targetDeviceName.trimmingCharacters(in: .whitespaces)
        return name.isEmpty ? "주변 기기 전체 검색" : "'\(name)' 기기 검색 시작"
    }

    private var scanButtonColor: Color {
        if !bt.isBluetoothOn { return .gray }
        return bt.isScanning ? .orange : .blue
    }

    private var statusColor: Color {
        let s = bt.connectionStatus
        if s.contains("연결됨") || s.contains("✅") { return .green }
        if s.contains("중") || s.contains("대기") { return .orange }
        return .red
    }
}
