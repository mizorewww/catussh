//
//  Form.swift
//  CatusshDesign
//
//  Grouped settings forms: caps group label above a `surface` card whose rows are
//  separated by `hairline` dividers.
//

import SwiftUI

/// Stacks its children with a divider between each pair.
public struct RXDividedStack<Content: View>: View {
    let inset: CGFloat
    let content: Content

    public init(inset: CGFloat = 0, @ViewBuilder content: () -> Content) {
        self.inset = inset
        self.content = content()
    }

    public var body: some View {
        _VariadicView.Tree(DividedLayout(inset: inset)) {
            content
        }
    }

    private struct DividedLayout: _VariadicView_MultiViewRoot {
        let inset: CGFloat

        @ViewBuilder
        func body(children: _VariadicView.Children) -> some View {
            let last = children.last?.id
            VStack(spacing: 0) {
                ForEach(children) { child in
                    child
                    if child.id != last {
                        Hairline().padding(.leading, inset)
                    }
                }
            }
        }
    }
}

/// A settings row: title and one-sentence description, control right-aligned.
public struct RXFormRow<Control: View>: View {
    let title: String
    let description: String?
    let alignTop: Bool
    let control: Control

    public init(_ title: String, description: String? = nil, alignTop: Bool = false, @ViewBuilder control: () -> Control) {
        self.title = title
        self.description = description
        self.alignTop = alignTop
        self.control = control()
    }

    public var body: some View {
        HStack(alignment: alignTop ? .top : .center, spacing: RX.Space.s6) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.rxBody)
                    .foregroundStyle(.rxInk)
                if let description, !description.isEmpty {
                    HelpText(description)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            control
        }
        .padding(.vertical, 10)
        .frame(minHeight: RX.formRowMinHeight)
    }
}

/// A boolean preference: title, description and a switch on the right.
public struct SwitchRow: View {
    let title: String
    let description: String?
    @Binding var isOn: Bool

    public init(_ title: String, description: String? = nil, isOn: Binding<Bool>) {
        self.title = title
        self.description = description
        _isOn = isOn
    }

    public var body: some View {
        RXFormRow(title, description: description) {
            Toggle(title, isOn: $isOn)
                .labelsHidden()
                .rxSwitchToggle()
                .tint(.rxAccent)
                #if os(macOS) || targetEnvironment(macCatalyst)
                .controlSize(.small)
                #endif
        }
    }
}

/// A bounded number: a continuous slider and a number field side by side. The
/// slider snaps to `step` without drawing tick marks and writes the binding once,
/// when the drag ends; the field takes an exact value (clamped to the range) on
/// Return or when it loses focus.
public struct RXSlider: View {
    @Binding var value: Double
    let range: ClosedRange<Double>
    let step: Double
    let unit: String?
    @State private var draft: Double?
    @State private var text = ""
    @FocusState private var fieldFocused: Bool

    public init(value: Binding<Double>, in range: ClosedRange<Double>, step: Double = 1, unit: String? = nil) {
        _value = value
        self.range = range
        self.step = step
        self.unit = unit
    }

    private var current: Double { draft ?? value }

    /// Decimals shown in the field: as many as the step needs.
    private var decimals: Int {
        guard step > 0, step < 1 else { return 0 }
        var places = 0
        var scaled = step
        while places < 4, abs(scaled.rounded() - scaled) > 1e-9 {
            scaled *= 10
            places += 1
        }
        return places
    }

    private func format(_ number: Double) -> String {
        String(format: "%.\(decimals)f", number)
    }

    private func snap(_ raw: Double) -> Double {
        guard step > 0 else { return raw }
        let snapped = ((raw - range.lowerBound) / step).rounded() * step + range.lowerBound
        return clamp(snapped)
    }

    private func clamp(_ number: Double) -> Double {
        min(range.upperBound, max(range.lowerBound, number))
    }

    private func commitText() {
        let cleaned = text.trimmingCharacters(in: .whitespaces)
            .replacingOccurrences(of: ",", with: ".")
            .trimmingCharacters(in: CharacterSet(charactersIn: unit ?? "").union(.whitespaces))
        if let typed = Double(cleaned) {
            let next = clamp(typed)
            if next != value { value = next }
            text = format(next)
        } else {
            text = format(value)
        }
    }

    public var body: some View {
        HStack(spacing: RX.Space.s2) {
            Slider(
                value: Binding(get: { current }, set: { draft = snap($0); text = format(snap($0)) }),
                in: range
            ) { editing in
                guard !editing, let draft else { return }
                if draft != value { value = draft }
                self.draft = nil
            }
            .labelsHidden()
            .tint(.rxAccent)
            .frame(width: 136)
            #if os(macOS) || targetEnvironment(macCatalyst)
            .controlSize(.small)
            #endif
            TextField("Value", text: $text)
                .labelsHidden()
                .multilineTextAlignment(.trailing)
                .font(.rxBody.monospacedDigit())
                .textFieldStyle(.rx)
                .frame(width: 56)
                .focused($fieldFocused)
                .onSubmit(commitText)
                .onChange(of: fieldFocused) { focused in
                    if !focused { commitText() }
                }
            if let unit {
                Text(unit)
                    .font(.rxBody)
                    .foregroundStyle(.rxInkSecondary)
            }
        }
        .onAppear { text = format(value) }
        .onChange(of: value) { newValue in
            if !fieldFocused { text = format(newValue) }
        }
    }
}

/// A right-aligned number field with an optional unit. The field is a draft
/// while typing; the value is written (clamped to the range) on Return or
/// when the field loses focus, so "25" can be typed inside 10...60.
public struct NumberFieldRow: View {
    let title: String
    let description: String?
    @Binding var value: Int
    let range: ClosedRange<Int>
    let unit: String?
    @State private var text = ""
    @FocusState private var fieldFocused: Bool

    public init(_ title: String, description: String? = nil, value: Binding<Int>, in range: ClosedRange<Int>, unit: String? = nil) {
        self.title = title
        self.description = description
        _value = value
        self.range = range
        self.unit = unit
    }

    private func commitText() {
        let cleaned = text.trimmingCharacters(in: .whitespaces)
        if let typed = Int(cleaned) {
            let next = min(range.upperBound, max(range.lowerBound, typed))
            if next != value { value = next }
            text = String(next)
        } else {
            text = String(value)
        }
    }

    public var body: some View {
        RXFormRow(title, description: description) {
            HStack(spacing: RX.Space.s2) {
                TextField(title, text: $text)
                    .multilineTextAlignment(.trailing)
                    .textFieldStyle(.rx)
                    .frame(width: 72)
                    .focused($fieldFocused)
                    .onSubmit(commitText)
                    .onChange(of: fieldFocused) { focused in
                        if !focused { commitText() }
                    }
                Stepper(title, value: $value, in: range)
                    .labelsHidden()
                if let unit {
                    Text(unit)
                        .font(.rxBody)
                        .foregroundStyle(.rxInkSecondary)
                }
            }
        }
        .onAppear { text = String(value) }
        .onChange(of: value) { newValue in
            if !fieldFocused { text = String(newValue) }
        }
    }
}

/// Page-level section title with optional count and trailing controls.
public struct SectionTitle<Trailing: View>: View {
    let title: String
    let count: Int?
    let trailing: Trailing

    public init(_ title: String, count: Int? = nil, @ViewBuilder trailing: () -> Trailing) {
        self.title = title
        self.count = count
        self.trailing = trailing()
    }

    public var body: some View {
        HStack(spacing: RX.Space.s2) {
            Text(title)
                .font(.rxSectionTitle)
                .foregroundStyle(.rxInk)
            if let count {
                CapsLabel("\(count)")
            }
            Spacer(minLength: 0)
            trailing
        }
        .frame(height: RX.controlHeight)
    }
}

public extension SectionTitle where Trailing == EmptyView {
    init(_ title: String, count: Int? = nil) {
        self.init(title, count: count) { EmptyView() }
    }
}
