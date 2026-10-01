import SwiftUI
import StreamCore

/// G11 (issue #117): the annotation toolbar — tool picker (pen, highlighter,
/// laser pointer), color and width, stroke undo/clear, and the two explicit
/// per-scene gates: visibility and "annotations are part of program".
///
/// **Mounting hook (orchestrator; G02 owns MainWindowView.swift).** Insert
/// `AnnotationToolbarView()` into `MainWindowView.canvasPanel` between the
/// `monitorsRow` block and `transitionControls` (it needs the existing
/// `dispatcher`/`previewProgram` environment objects — nothing else). All
/// controls live in the main window; every action routes through the
/// dispatcher, and every action also has a menu item + hotkey in
/// StreamMacApp's Annotate menu, so the toolbar is a convenience, never the
/// only path.
///
/// **Program honesty.** The "In Program" toggle is the explicit choice the
/// issue demands: off, strokes are preview-monitor-only telestrator marks
/// (SwiftUI chrome over the PREVIEW monitor); on, they composite into the
/// program output through `AnnotationRenderer`. Editor chrome (selection
/// handles, guides, the in-progress stroke) is never program content by
/// construction — it exists only in the preview overlay view.
struct AnnotationToolbarView: View {
    @EnvironmentObject private var dispatcher: StudioCommandDispatcher
    @EnvironmentObject private var previewProgram: PreviewProgramModel

    private var annotations: AnnotationStore { dispatcher.annotations }
    /// The reactive mirror (the dispatcher's published state) — reading this
    /// instead of the nested store keeps the view refreshing.
    private var uiState: AnnotationUIState { dispatcher.state.annotations }
    private var stagedSceneID: SceneID? { previewProgram.stagedScene?.id }

    var body: some View {
        HStack(spacing: 12) {
            toolPicker
            Divider().frame(height: 18)
            colorSwatches
            widthControl
            Divider().frame(height: 18)
            undoClearButtons
            Spacer()
            gateToggles
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
        .disabled(stagedSceneID == nil)
    }

    // MARK: Tool picker

    /// Nil selection = the canvas's normal selection mode. Picking a tool
    /// routes through the dispatcher so menu, toolbar, and automation agree.
    private var toolPicker: some View {
        Picker("Annotation Tool", selection: toolBinding) {
            Text("Select").tag(AnnotationTool?.none)
            ForEach(AnnotationTool.allCases, id: \.self) { tool in
                Text(tool.displayName).tag(AnnotationTool?.some(tool))
            }
        }
        .pickerStyle(.segmented)
        .frame(maxWidth: 280)
        .help("Draw on the preview canvas: pen, highlighter, or laser pointer")
    }

    private var toolBinding: Binding<AnnotationTool?> {
        Binding(
            get: { uiState.activeTool },
            set: { dispatcher.execute(.setAnnotationTool($0)) })
    }

    // MARK: Color & width (session state — direct store edits, not commands)

    private var colorSwatches: some View {
        HStack(spacing: 4) {
            ForEach(AnnotationStore.palette, id: \.self) { hex in
                let components = HexColor.components(hex)
                Button {
                    annotations.colorHex = hex
                } label: {
                    Circle()
                        .fill(Color(.sRGB, red: components.red, green: components.green,
                                    blue: components.blue, opacity: 1))
                        .frame(width: 14, height: 14)
                        .overlay(Circle().stroke(Color.white,
                                                 lineWidth: uiState.colorHex == hex ? 2 : 0))
                }
                .buttonStyle(.plain)
                .help("Annotation color")
            }
        }
    }

    @ViewBuilder
    private var widthControl: some View {
        if let tool = uiState.activeTool, tool.leavesStroke {
            let binding = Binding<Double>(
                get: { tool == .highlighter ? uiState.highlighterWidth : uiState.penWidth },
                set: { value in
                    if tool == .highlighter {
                        annotations.highlighterWidth = value
                    } else {
                        annotations.penWidth = value
                    }
                })
            Slider(value: binding, in: AnnotationStroke.widthRange) {
                Text("Width")
            }
            .frame(width: 90)
            .help("\(tool.displayName) width")
        }
    }

    // MARK: Undo / clear

    private var undoClearButtons: some View {
        HStack(spacing: 8) {
            Button {
                dispatcher.execute(.undoAnnotationStroke(in: nil))
            } label: {
                Label("Undo Stroke", systemImage: "arrow.uturn.backward")
            }
            .disabled(!dispatcher.canExecute(.undoAnnotationStroke(in: nil)))
            .help("Remove the most recent stroke (⌥⌘Z)")

            Button {
                dispatcher.execute(.clearAnnotations(in: nil))
            } label: {
                Label("Clear", systemImage: "trash")
            }
            .disabled(!dispatcher.canExecute(.clearAnnotations(in: nil)))
            .help("Remove all strokes from the staged scene (⌥⌘K) — undoable")
        }
        .labelStyle(.iconOnly)
    }

    // MARK: The explicit per-scene gates

    private var gateToggles: some View {
        HStack(spacing: 12) {
            Toggle(isOn: visibleBinding) {
                Text("Visible")
                    .font(.callout)
            }
            .toggleStyle(.switch)
            .controlSize(.small)
            .help("Show this scene's annotations in the studio (⌥⌘V)")

            Toggle(isOn: inProgramBinding) {
                Text("In Program")
                    .font(.callout)
            }
            .toggleStyle(.switch)
            .controlSize(.small)
            .help("Broadcast this scene's annotations in the program output (⌥⌘B) — off keeps them preview-only")
        }
    }

    private var visibleBinding: Binding<Bool> {
        Binding(
            get: { dispatcher.state.annotations.stagedVisible },
            set: { dispatcher.execute(.setAnnotationVisibility(visible: $0, in: nil)) })
    }

    private var inProgramBinding: Binding<Bool> {
        Binding(
            get: { dispatcher.state.annotations.stagedInProgram },
            set: { dispatcher.execute(.setAnnotationsInProgram($0, in: nil)) })
    }
}
