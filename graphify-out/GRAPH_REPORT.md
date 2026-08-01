# Graph Report - /Users/p.vamshikrishna/Library/Mobile Documents/com~apple~CloudDocs/Desktop/paste/paste  (2026-07-19)

## Corpus Check
- cluster-only mode — file stats not available

## Summary
- 1450 nodes · 3972 edges · 62 communities (56 shown, 6 thin omitted)
- Extraction: 96% EXTRACTED · 4% INFERRED · 0% AMBIGUOUS · INFERRED: 143 edges (avg confidence: 0.8)
- Token cost: 0 input · 0 output

## Graph Freshness
- Built from commit: `4ea97704`
- Run `git rev-parse HEAD` and compare to check if the graph is stale.
- Run `graphify update .` after code changes (no API cost).

## Community Hubs (Navigation)
- NSImage
- ClipboardItem
- ReferenceCarousel
- TrackingService
- NSPopover
- InteractionLabController
- FileKindDetector
- ClipboardManager
- MainWindowView
- ClipboardManager
- ClipboardTag
- .commitPaste
- AppDelegate
- ClipboardManager
- ClipboardManager
- Context
- ClipenSettingsView
- .registerActionUsage
- ClipboardManager
- ItemPreviewPanel.swift
- ClipboardManager
- AppKit
- AutoPreviewContentType
- PreviewOverlayWindow
- InteractionDemo
- View
- ClipboardContent
- .imagePreview
- FastPasteHintPanel.swift
- String
- DragSourceView
- NSColor
- .flashStatus
- Coordinator
- QuickLookController
- .commitLanguagePickerTranslation
- ClipboardContentType
- TutorialSheet
- Bool
- FitOnLayoutScrollView
- .candidates
- URL
- PageRangePanel.swift
- NSAttributedString
- Int
- Keychain
- AIService
- InteractionToneGenerator
- InteractionSound
- AppContextService
- ImageTools.swift
- ItemTagStrip
- Foundation
- CodeLanguageDetector
- DetectionCandidate
- Step
- pasteApp.swift
- SystemPopoverMaterial
- QuickLookFilePreview
- .write
- FeedbackSendState
- OnboardingView

## God Nodes (most connected - your core abstractions)
1. `String` - 289 edges
2. `ClipboardItem` - 163 edges
3. `View` - 109 edges
4. `ClipboardManager` - 76 edges
5. `NSImage` - 56 edges
6. `ClipboardTag` - 52 edges
7. `ClipboardManager` - 50 edges
8. `InteractionLabController` - 47 edges
9. `ImageService` - 39 edges
10. `AppKit` - 34 edges

## Surprising Connections (you probably didn't know these)
- `ClipboardManager` --calls--> `FastPasteHintPanel`  [INFERRED]
  paste/ClipboardManager.swift → paste/FastPasteHintPanel.swift
- `ClipboardManager` --calls--> `ItemPreviewPanel`  [INFERRED]
  paste/ClipboardManager.swift → paste/ItemPreviewPanel.swift
- `ClipboardManager` --calls--> `PreviewOverlayWindow`  [INFERRED]
  paste/ClipboardManager.swift → paste/PreviewOverlayWindow.swift
- `ClipboardManager` --calls--> `SharePanel`  [INFERRED]
  paste/ClipboardManager.swift → paste/SharePanel.swift
- `ClipboardManager` --calls--> `TransformPanel`  [INFERRED]
  paste/ClipboardManager.swift → paste/TransformPanel.swift

## Import Cycles
- None detected.

## Communities (62 total, 6 thin omitted)

### Community 0 - "NSImage"
Cohesion: 0.05
Nodes (42): CGImageSource, NSBitmapImageRep, os, NSImage, Data, CachedDataThumbnail, CachedFileThumbnail, ClipenIconCache (+34 more)

### Community 1 - "ClipboardItem"
Cohesion: 0.05
Nodes (42): Identifiable, ClipboardItem, Bool, NSItemProvider, Float, NSItemProvider, NSPasteboardWriting, MarkedClass (+34 more)

### Community 2 - "ReferenceCarousel"
Cohesion: 0.06
Nodes (37): Edge, Kind, ObservableObject, CollapsedReferenceBadge, DiffHighlightText, DragHandleNSView, EditableTableGrid, Kind (+29 more)

### Community 3 - "TrackingService"
Cohesion: 0.08
Nodes (30): Codable, CodingKey, Decodable, Decoder, AuthManager, CodingKeys, actions, captures (+22 more)

### Community 4 - "NSPopover"
Cohesion: 0.06
Nodes (34): AnyView, NSPopoverDelegate, ItemPreviewPanel, CGFloat, Notification, NSPanel, NSPoint, NSRect (+26 more)

### Community 5 - "InteractionLabController"
Cohesion: 0.16
Nodes (20): CVarArg, InteractionLabController, LabItem, LabKey, b, backspace, c, cmd (+12 more)

### Community 6 - "FileKindDetector"
Cohesion: 0.13
Nodes (14): DateComponentsFormatter, DateFormatter, FileKindDetector, Bool, Int, URL, FileTools, Bool (+6 more)

### Community 7 - "ClipboardManager"
Cohesion: 0.12
Nodes (14): CryptoKit, JSONDecoder, ClipboardManager, HistoryCrypto, PersistedItem, Bool, Data, Date (+6 more)

### Community 8 - "MainWindowView"
Cohesion: 0.08
Nodes (25): ClipboardManager, Element, Array, Color, CompactItemRow, ConfigView, HistoryListPane, ItemDetailView (+17 more)

### Community 9 - "ClipboardManager"
Cohesion: 0.13
Nodes (9): ClipboardManager, Bool, Data, NSPasteboard, Set, URL, UUID, FileSnapshotStore (+1 more)

### Community 10 - "ClipboardTag"
Cohesion: 0.06
Nodes (34): Hashable, ClipboardTag, address, archive, audio, blob, code, color (+26 more)

### Community 11 - ".commitPaste"
Cohesion: 0.19
Nodes (8): CGEvent, ClipboardManager, Bool, Int, NSRunningApplication, Set, UUID, Void

### Community 12 - "AppDelegate"
Cohesion: 0.11
Nodes (16): NSApplication, NSApplicationDelegate, AppDelegate, Bool, Error, Int, Notification, Set (+8 more)

### Community 13 - "ClipboardManager"
Cohesion: 0.13
Nodes (10): ClipboardManager, ImageSimilarityService, Bool, CGImage, Date, Float, Int, NSPanel (+2 more)

### Community 14 - "ClipboardManager"
Cohesion: 0.09
Nodes (15): AnyCancellable, CFMachPort, CFRunLoopSource, NLEmbedding, NSObjectProtocol, ClipboardManager, PageRangeOutputMode, combinedPDF (+7 more)

### Community 15 - "Context"
Cohesion: 0.15
Nodes (12): AVPlayerView, NSScrollView, NSViewRepresentable, AttributedTextPreview, AVMediaPreview, HighlightedCodeTextView, HTMLFilePreview, HTMLStringPreview (+4 more)

### Community 16 - "ClipenSettingsView"
Cohesion: 0.18
Nodes (7): Binding, ClipenSettingsView, Bool, Double, Int, LocalizedStringKey, Void

### Community 18 - "ClipboardManager"
Cohesion: 0.16
Nodes (3): ClipboardManager, NSPoint, NSSharingService

### Community 19 - "ItemPreviewPanel.swift"
Cohesion: 0.11
Nodes (22): AVKit, ModelIO, AsyncTextFilePreview, Block, DelimitedTablePreview, ExtractedLink, InsightsStrip, Kind (+14 more)

### Community 20 - "ClipboardManager"
Cohesion: 0.20
Nodes (8): CGEventTapProxy, CGEventType, ClipboardManager, Bool, CGEvent, Int, Int64, Unmanaged

### Community 21 - "AppKit"
Cohesion: 0.18
Nodes (9): Accelerate, AppKit, ApplicationServices, NaturalLanguage, PDFKit, ServiceManagement, SwiftUI, UniformTypeIdentifiers (+1 more)

### Community 22 - "AutoPreviewContentType"
Cohesion: 0.09
Nodes (20): AutoPreviewContentType, blob, code, color, email, file, files, html (+12 more)

### Community 23 - "PreviewOverlayWindow"
Cohesion: 0.15
Nodes (17): DoubleSpaceKeyFlatHint, FlatHint, IconFlatHint, PopoverDragPreview, PopoverMiniTable, PopoverPreviewView, PopoverRow, PreviewOverlayWindow (+9 more)

### Community 24 - "InteractionDemo"
Cohesion: 0.09
Nodes (22): CaseIterable, GestureSpeed, fast, medium, slow, InteractionDemo, cycle, cyclePinned (+14 more)

### Community 25 - "View"
Cohesion: 0.16
Nodes (15): C, K, InteractionLabStage, InteractionPreviewCard, LabKeyCapView, LabMockPanel, LabSidePanel, Row1HeightKey (+7 more)

### Community 26 - "ClipboardContent"
Cohesion: 0.13
Nodes (14): ClipboardContent, blob, file, files, html, image, richText, rtfd (+6 more)

### Community 27 - ".imagePreview"
Cohesion: 0.18
Nodes (7): InteractivePDFView, PDFPreview, SpinUntilTouchedSCNView, NSEvent, NSPasteboard, PDFDocument, PDFView

### Community 28 - "FastPasteHintPanel.swift"
Cohesion: 0.17
Nodes (13): NSPanel, AnimatedGestureDemo, FastPasteHintPanel, FastPasteHintView, Keycap, LoopToken, MiniPickerChip, Any (+5 more)

### Community 29 - "String"
Cohesion: 0.24
Nodes (4): AppLanguage, String, Bool, TextTools

### Community 30 - "DragSourceView"
Cohesion: 0.16
Nodes (11): NSDraggingContext, NSDraggingSession, NSDraggingSource, NSDragOperation, NSView, DragSourceView, MultiItemDragSource, Context (+3 more)

### Community 31 - "NSColor"
Cohesion: 0.21
Nodes (6): NSColor, Date, UUID, ContentDetector, URL, TagDetector

### Community 32 - ".flashStatus"
Cohesion: 0.12
Nodes (7): Any, CGFloat, Data, PDFDocument, PDFPage, URL, UUID

### Community 33 - "Coordinator"
Cohesion: 0.17
Nodes (9): NSObject, NSProgressIndicator, Coordinator, Model3DPreview, Error, SCNScene, SCNView, WKNavigation (+1 more)

### Community 34 - "QuickLookController"
Cohesion: 0.18
Nodes (10): QuickLookController, Data, Int, URL, UUID, QLPreviewItem, QLPreviewPanel, QLPreviewPanelDataSource (+2 more)

### Community 36 - "ClipboardContentType"
Cohesion: 0.13
Nodes (14): ClipboardContentType, address, code, email, hexColor, json, latex, markdown (+6 more)

### Community 37 - "TutorialSheet"
Cohesion: 0.22
Nodes (7): Bool, Int, LocalizedStringKey, Set, UUID, Void, TutorialSheet

### Community 38 - "Bool"
Cohesion: 0.21
Nodes (8): Equatable, Highlightr, CodeHighlighter, Entry, FolderTreePreview, HighlightKey, ItemPreviewView, Bool

### Community 39 - "FitOnLayoutScrollView"
Cohesion: 0.25
Nodes (6): NSClickGestureRecognizer, NSImageView, AnimatedImageView, FitOnLayoutScrollView, Data, ZoomableImagePreview

### Community 40 - ".candidates"
Cohesion: 0.32
Nodes (4): Bool, Bool, Set, TextTraditionalDetectors

### Community 41 - "URL"
Cohesion: 0.31
Nodes (6): Chrome, panel, reference, ContentPreviewView, FilePreviewContent, URL

### Community 42 - "PageRangePanel.swift"
Cohesion: 0.17
Nodes (10): Combine, BlinkingCursor, InlineLanguagePicker, InlinePagePicker, PageRangeParser, Bool, Double, Int (+2 more)

### Community 43 - "NSAttributedString"
Cohesion: 0.29
Nodes (7): NSArray, NSCache, NSUUID, CodeSyntaxPreview, EmbeddedImageExtractor, NSAttributedString, TableCellExtractor

### Community 44 - "Int"
Cohesion: 0.29
Nodes (5): NSRegularExpression, LinkExtractor, MiniTablePreview, Int, TextInsightExtractor

### Community 45 - "Keychain"
Cohesion: 0.21
Nodes (4): Keychain, Bool, Data, Security

### Community 46 - "AIService"
Cohesion: 0.24
Nodes (4): AIService, Bool, CGImage, Int

### Community 47 - "InteractionToneGenerator"
Cohesion: 0.20
Nodes (6): AVAudioFormat, AVFoundation, InteractionToneGenerator, Double, Float, MediaTools

### Community 48 - "InteractionSound"
Cohesion: 0.18
Nodes (11): InteractionSound, category, cycle, delete, mark, moveFront, pin, preview (+3 more)

### Community 50 - "ImageTools.swift"
Cohesion: 0.29
Nodes (6): CoreGraphics, FoundationModels, ImageIO, ImageTools, OCRService, webp

### Community 51 - "ItemTagStrip"
Cohesion: 0.32
Nodes (7): ItemTagStrip, ItemTagStripStyle, chips, plainComma, Bool, Int, TagChip

### Community 52 - "Foundation"
Cohesion: 0.29
Nodes (3): Foundation, IOKit, DeviceIdentity

### Community 54 - "DetectionCandidate"
Cohesion: 0.33
Nodes (6): DetectionCandidate, DetectionMethod, deterministic, semantic, DetectionRegex, Double

### Community 55 - "Step"
Cohesion: 0.29
Nodes (7): Step, cmdDown, idle, pickerShown, ringFull, vDown, vUp

### Community 56 - "pasteApp.swift"
Cohesion: 0.33
Nodes (5): App, pasteApp, WindowOpenBridge, Scene, Sparkle

### Community 57 - "SystemPopoverMaterial"
Cohesion: 0.60
Nodes (3): Context, NSVisualEffectView, SystemPopoverMaterial

### Community 59 - ".write"
Cohesion: 0.31
Nodes (4): NSPasteboardItem, Data, NSPasteboard, URL

### Community 60 - "FeedbackSendState"
Cohesion: 0.50
Nodes (4): FeedbackSendState, failed, idle, sent

## Knowledge Gaps
- **164 isolated node(s):** `cmdVPastes`, `fastPastes`, `CryptoKit`, `Accelerate`, `ServiceManagement` (+159 more)
  These have ≤1 connection - possible missing edges or undocumented components.
- **6 thin communities (<3 nodes) omitted from report** — run `graphify query` to explore isolated nodes.

## Suggested Questions
_Questions this graph is uniquely positioned to answer:_

- **Why does `String` connect `String` to `NSImage`, `ClipboardItem`, `ReferenceCarousel`, `TrackingService`, `NSPopover`, `InteractionLabController`, `FileKindDetector`, `ClipboardManager`, `MainWindowView`, `ClipboardManager`, `ClipboardTag`, `.commitPaste`, `AppDelegate`, `ClipboardManager`, `ClipboardManager`, `Context`, `ClipenSettingsView`, `.registerActionUsage`, `ClipboardManager`, `ItemPreviewPanel.swift`, `AppKit`, `AutoPreviewContentType`, `PreviewOverlayWindow`, `InteractionDemo`, `ClipboardContent`, `FastPasteHintPanel.swift`, `NSColor`, `.flashStatus`, `Coordinator`, `QuickLookController`, `ClipboardContentType`, `TutorialSheet`, `Bool`, `.candidates`, `URL`, `PageRangePanel.swift`, `NSAttributedString`, `Int`, `Keychain`, `AIService`, `AppContextService`, `Foundation`, `CodeLanguageDetector`, `DetectionCandidate`, `OnboardingView`?**
  _High betweenness centrality (0.528) - this node is a cross-community bridge._
- **Why does `ClipboardItem` connect `ClipboardItem` to `NSImage`, `ReferenceCarousel`, `NSPopover`, `FileKindDetector`, `ClipboardManager`, `MainWindowView`, `ClipboardManager`, `ClipboardTag`, `.commitPaste`, `ClipboardManager`, `ClipboardManager`, `ClipboardManager`, `ItemPreviewPanel.swift`, `AppKit`, `AutoPreviewContentType`, `PreviewOverlayWindow`, `ClipboardContent`, `String`, `NSColor`, `.flashStatus`, `QuickLookController`, `ClipboardContentType`, `Bool`, `URL`, `NSAttributedString`, `.write`?**
  _High betweenness centrality (0.225) - this node is a cross-community bridge._
- **Why does `ClipboardManager` connect `ClipboardManager` to `.flashStatus`, `ClipboardItem`, `ReferenceCarousel`, `NSPopover`, `ClipboardTag`, `.commitPaste`, `InteractionToneGenerator`, `InteractionSound`, `AppContextService`, `AppKit`, `AutoPreviewContentType`, `PreviewOverlayWindow`, `InteractionDemo`, `ClipboardContent`, `FastPasteHintPanel.swift`, `String`, `NSColor`?**
  _High betweenness centrality (0.078) - this node is a cross-community bridge._
- **Are the 5 inferred relationships involving `String` (e.g. with `.importLegacyDefaults()` and `.fetchURLTitle()`) actually correct?**
  _`String` has 5 INFERRED edges - model-reasoned connections that need verification._
- **Are the 6 inferred relationships involving `ClipboardItem` (e.g. with `.fileURLs()` and `.itemCount()`) actually correct?**
  _`ClipboardItem` has 6 INFERRED edges - model-reasoned connections that need verification._
- **Are the 6 inferred relationships involving `NSImage` (e.g. with `.addItem()` and `.basicItem()`) actually correct?**
  _`NSImage` has 6 INFERRED edges - model-reasoned connections that need verification._
- **What connects `cmdVPastes`, `fastPastes`, `CryptoKit` to the rest of the system?**
  _164 weakly-connected nodes found - possible documentation gaps or missing edges._