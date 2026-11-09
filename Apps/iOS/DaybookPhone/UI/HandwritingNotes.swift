import DaybookUI
import PencilKit
import SwiftUI
import UIKit
import Vision

/// Appends reviewed handwriting as new note paragraphs without changing the notes already there.
enum HandwritingNotes {
 static func appending(_ reviewed: String, to notes: String) -> String? {
  let text = reviewed.trimmingCharacters(in: .whitespacesAndNewlines)
  guard !text.isEmpty else { return nil }
  guard !notes.isEmpty else { return text }

  // Whitespace after a line break belongs to the existing blank line, not a new paragraph.
  let trailing = notes.unicodeScalars.reversed().prefix {
   CharacterSet.whitespacesAndNewlines.contains($0)
  }
  let hasLineBreak = trailing.contains { CharacterSet.newlines.contains($0) }
  let onlyWhitespace = notes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
  return notes + (hasLineBreak || onlyWhitespace ? "" : "\n") + text
 }
}

/// The same entry point beside the filed and recording notes. The binding is read again when the
/// person confirms, so notes arriving while the handwriting sheet is open are retained.
struct HandwritingButton: View {
 @Binding var text: String
 let canInsert: () -> Bool
 let onPresentationChange: (Bool) -> Void
 @State private var showing = false

 init(
  text: Binding<String>, canInsert: @escaping () -> Bool,
  onPresentationChange: @escaping (Bool) -> Void = { _ in }
 ) {
  _text = text
  self.canInsert = canInsert
  self.onPresentationChange = onPresentationChange
 }

 var body: some View {
  Button {
   UIApplication.shared.sendAction(
    #selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
   onPresentationChange(true)
   showing = true
  } label: {
   Image(systemName: "pencil.tip.crop.circle")
    .font(.body)
    .frame(width: 44, height: 44)
    .contentShape(Rectangle())
  }
  .foregroundStyle(PhoneStyle.Ink.link)
  .accessibilityLabel("Add handwriting")
  .accessibilityHint("Write and review text before adding it to your notes.")
  .sheet(isPresented: $showing, onDismiss: { onPresentationChange(false) }) {
   HandwritingSheet(text: $text, canInsert: canInsert)
  }
 }
}

/// Ink is kept only in this sheet. Vision runs only on request, and its result is editable before it
/// goes through the same binding as the notes editor.
private struct HandwritingSheet: View {
 @Binding var text: String
 let canInsert: () -> Bool
 @Environment(\.dismiss) private var dismiss
 @Environment(\.surfaceStyle) private var surface
 @State private var canvas = PKCanvasView()
 @State private var hasInk = false
 @State private var erasing = false
 @State private var draft = ""
 @State private var recognized: String?
 @State private var inkChanged = false
 @State private var reviewing = false
 @State private var recognizing = false
 @State private var recognitionTask: Task<Void, Never>?
 @State private var problem: String?
 @State private var confirmingDiscard = false
 @State private var confirmingClear = false
 @State private var confirmingReplacement = false

 init(text: Binding<String>, canInsert: @escaping () -> Bool) {
  _text = text
  self.canInsert = canInsert
 }

 var body: some View {
  Group {
   if surface == .pocket {
    singlePage
   } else {
    // A system sheet can straddle the Duo's crease. Keep the canvas and review on
    // separate pages there; a sheet kept to one side remains a single column.
    SheetCreaseSplit {
     drawingPage(split: true)
    } trailing: {
     reviewPage(split: true)
    } single: {
     singlePage
    }
   }
  }
  .presentationSizing(SheetPagesSizing(asPages: surface != .pocket))
  .guardingDismissal(hasInk || recognized != nil || recognizing)
  .confirmationDialog(
   "Discard handwriting?", isPresented: $confirmingDiscard, titleVisibility: .visible
  ) {
   Button("Discard Handwriting", role: .destructive) { dismiss() }
   Button("Keep Editing", role: .cancel) {}
  } message: {
   Text("The handwriting and reviewed text have not been added to your notes.")
  }
  .confirmationDialog(
   "Clear handwriting?", isPresented: $confirmingClear, titleVisibility: .visible
  ) {
   Button("Clear Handwriting", role: .destructive) {
    canvas.drawing = PKDrawing()
    hasInk = false
    if recognized != nil { inkChanged = true }
    problem = nil
   }
   Button("Keep Writing", role: .cancel) {}
  } message: {
   Text("This removes the handwriting from the canvas.")
  }
  .confirmationDialog(
   "Replace edited text?", isPresented: $confirmingReplacement, titleVisibility: .visible
  ) {
   Button("Replace Text", role: .destructive) { recognize() }
   Button("Keep Editing", role: .cancel) {}
  } message: {
   Text("Recognizing again will replace your edits to the previous result.")
  }
  .onDisappear { recognitionTask?.cancel() }
 }

 @ViewBuilder private var singlePage: some View {
  if reviewing { reviewPage(split: false) } else { drawingPage(split: false) }
 }

 private func drawingPage(split: Bool) -> some View {
  NavigationStack {
   VStack(alignment: .leading, spacing: PhoneStyle.Space.s3) {
    Text("Write with a compatible stylus or your finger, then recognize the text.")
     .font(PhoneStyle.Typeface.status)
     .foregroundStyle(PhoneStyle.Ink.secondary)
    Picker("Handwriting tool", selection: $erasing) {
     Label("Write", systemImage: "pencil.tip").tag(false)
     Label("Erase", systemImage: "eraser").tag(true)
    }
    .pickerStyle(.segmented)
    .disabled(recognizing)
    .onChange(of: erasing) { _, value in
     if value {
      canvas.tool = PKEraserTool(.vector)
     } else {
      canvas.tool = PKInkingTool(.pen, color: .black, width: 3)
     }
    }
    HandwritingCanvas(canvas: canvas, erasing: erasing, enabled: !recognizing) { canvas in
     let newHasInk = !canvas.drawing.bounds.isEmpty
     if hasInk != newHasInk { hasInk = newHasInk }
     if recognized != nil && !inkChanged { inkChanged = true }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background(.white)
    .clipShape(RoundedRectangle(cornerRadius: 10))
    .overlay { RoundedRectangle(cornerRadius: 10).stroke(Color(uiColor: .separator), lineWidth: 1) }

    ViewThatFits(in: .horizontal) {
     HStack(spacing: PhoneStyle.Space.s3) {
      clearButton
      Spacer()
      recognizeButton
     }
     VStack(alignment: .trailing, spacing: PhoneStyle.Space.s2) {
      recognizeButton
      clearButton
     }
     .frame(maxWidth: .infinity, alignment: .trailing)
    }
    if let problem { problemLabel(problem) }
   }
   .padding(PhoneStyle.Space.s4)
   .navigationTitle("Handwriting")
   .navigationBarTitleDisplayMode(.inline)
   .toolbar {
    ToolbarItem(placement: .cancellationAction) { Button("Cancel", action: cancel) }
    if !split && recognized != nil {
     ToolbarItem(placement: .confirmationAction) {
      Button("Review") {
       reviewing = true
       problem = nil
      }
     }
    }
   }
  }
 }

 private var clearButton: some View {
  Button("Clear", role: .destructive) { confirmingClear = true }
   .frame(minHeight: 44)
   .disabled(!hasInk || recognizing)
   .accessibilityLabel("Clear handwriting")
 }

 private var recognizeButton: some View {
  Button(action: requestRecognition) {
   if recognizing {
    HStack {
     ProgressView()
     Text("Recognizing…")
    }
   } else {
    Label("Recognize Text", systemImage: "text.viewfinder")
   }
  }
  .buttonStyle(.borderedProminent)
  .disabled(recognizing)
 }

 private func reviewPage(split: Bool) -> some View {
  NavigationStack {
   VStack(alignment: .leading, spacing: PhoneStyle.Space.s3) {
    if recognized != nil {
     Text("Review and edit the text before adding it to your notes.")
      .font(PhoneStyle.Typeface.status)
      .foregroundStyle(PhoneStyle.Ink.secondary)
     if inkChanged {
      Text("Handwriting changed. Recognize it again to update this text.")
       .font(PhoneStyle.Typeface.status)
       .foregroundStyle(PhoneStyle.Ink.secondary)
     }
     TextEditor(text: $draft)
      .font(PhoneStyle.Typeface.body)
      .scrollContentBackground(.hidden)
      .padding(PhoneStyle.Space.s2)
      .frame(maxWidth: .infinity, maxHeight: .infinity)
      .background(
       Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: 10)
      )
      .accessibilityLabel("Recognized text")
      .disabled(recognizing)
     if draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
      Text("Enter some text before adding it.")
       .font(PhoneStyle.Typeface.status)
       .foregroundStyle(PhoneStyle.Ink.secondary)
     }
     if let problem { problemLabel(problem) }
    } else {
     ContentUnavailableView(
      "No Recognized Text", systemImage: "text.viewfinder",
      description: Text("Write on the canvas and tap Recognize Text.")
     )
     .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
   }
   .padding(PhoneStyle.Space.s4)
   .navigationTitle("Review Text")
   .navigationBarTitleDisplayMode(.inline)
   .toolbar {
    if !split {
     ToolbarItem(placement: .cancellationAction) {
      Button("Back") {
       reviewing = false
       problem = nil
      }
      .accessibilityLabel("Back to handwriting")
     }
    }
    ToolbarItem(placement: .confirmationAction) {
     Button("Add", action: insert)
      .disabled(
       recognized == nil || recognizing
        || draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      )
      .accessibilityLabel("Add recognized text to notes")
    }
   }
  }
 }

 private func problemLabel(_ message: String) -> some View {
  Label(message, systemImage: "exclamationmark.triangle")
   .font(PhoneStyle.Typeface.status)
   .foregroundStyle(PhoneStyle.Ink.warning)
   .fixedSize(horizontal: false, vertical: true)
 }

 private func showProblem(_ message: String) {
  problem = message
  AccessibilityNotification.Announcement(message).post()
 }

 private func cancel() {
  if hasInk || recognized != nil || recognizing { confirmingDiscard = true } else { dismiss() }
 }

 private func requestRecognition() {
  guard hasInk else {
   showProblem("Write something before recognizing text.")
   return
  }
  if let recognized, draft != recognized {
   confirmingReplacement = true
  } else {
   recognize()
  }
 }

 private func recognize() {
  guard let image = HandwritingRecognition.image(from: canvas.drawing) else {
   showProblem("The handwriting couldn’t be prepared for recognition. Try again.")
   return
  }
  problem = nil
  recognizing = true
  let work = Task.detached(priority: .userInitiated) { try HandwritingRecognition.text(in: image) }
  recognitionTask = Task {
   defer { recognizing = false }
   do {
    let result = try await work.value
    guard !Task.isCancelled else { return }
    guard !result.isEmpty else {
     showProblem("No text was recognized. Try writing more clearly and recognize it again.")
     return
    }
    draft = result
    recognized = result
    inkChanged = false
    reviewing = true
   } catch {
    guard !Task.isCancelled else { return }
    showProblem("Couldn’t recognize the handwriting: \(error.localizedDescription)")
   }
  }
 }

 private func insert() {
  guard let updated = HandwritingNotes.appending(draft, to: text) else {
   showProblem("Enter some text before adding it.")
   return
  }
  guard canInsert() else {
   showProblem("These notes are no longer available. Your text has not been added.")
   return
  }
  text = updated
  dismiss()
 }
}

private struct HandwritingCanvas: UIViewRepresentable {
 let canvas: PKCanvasView
 let erasing: Bool
 let enabled: Bool
 let changed: (PKCanvasView) -> Void

 func makeCoordinator() -> Coordinator { Coordinator(changed: changed) }

 func makeUIView(context: Context) -> PKCanvasView {
  canvas.backgroundColor = .white
  canvas.isOpaque = true
  canvas.overrideUserInterfaceStyle = .light
  canvas.drawingPolicy = .anyInput
  if erasing {
   canvas.tool = PKEraserTool(.vector)
  } else {
   canvas.tool = PKInkingTool(.pen, color: .black, width: 3)
  }
  canvas.isScrollEnabled = false
  canvas.isAccessibilityElement = true
  canvas.accessibilityTraits = .allowsDirectInteraction
  canvas.accessibilityLabel = "Handwriting canvas"
  canvas.accessibilityHint = "Write with a compatible stylus or your finger."
  canvas.delegate = context.coordinator
  return canvas
 }

 func updateUIView(_ view: PKCanvasView, context: Context) {
  context.coordinator.changed = changed
  view.delegate = context.coordinator
  view.isUserInteractionEnabled = enabled
 }

 final class Coordinator: NSObject, PKCanvasViewDelegate {
  var changed: (PKCanvasView) -> Void
  init(changed: @escaping (PKCanvasView) -> Void) { self.changed = changed }
  func canvasViewDrawingDidChange(_ canvasView: PKCanvasView) { changed(canvasView) }
 }
}

private enum HandwritingRecognition {
 /// Vision gets dark ink on opaque white even when the phone is in Dark Mode. Restrict the raster
 /// size while retaining a generous border around the strokes.
 @MainActor static func image(from drawing: PKDrawing) -> CGImage? {
  let inkBounds = drawing.bounds
  guard !inkBounds.isEmpty else { return nil }
  let bounds = inkBounds.insetBy(dx: -16, dy: -16)
  guard bounds.width > 0, bounds.height > 0 else { return nil }
  let scale = min(3, 2048 / max(bounds.width, bounds.height))
  let ink = drawing.image(from: bounds, scale: scale)
  let format = UIGraphicsImageRendererFormat()
  format.scale = scale
  format.opaque = true
  let rect = CGRect(origin: .zero, size: bounds.size)
  return UIGraphicsImageRenderer(size: bounds.size, format: format).image { context in
   UIColor.white.setFill()
   context.fill(rect)
   ink.draw(in: rect)
  }.cgImage
 }

 static func text(in image: CGImage) throws -> String {
  let request = VNRecognizeTextRequest()
  request.recognitionLevel = .accurate
  request.usesLanguageCorrection = true
  request.automaticallyDetectsLanguage = true
  try VNImageRequestHandler(cgImage: image, options: [:]).perform([request])
  return (request.results ?? []).compactMap { observation in
   guard let line = observation.topCandidates(1).first?.string.trimmingCharacters(in: .whitespaces),
    !line.isEmpty
   else { return nil }
   return line
  }.joined(separator: "\n")
 }
}
