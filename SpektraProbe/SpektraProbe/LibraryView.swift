//  LibraryView.swift — the library: a column beside the picture on an iPad, a
//  grid in a sheet on an iPhone. Each photo as it was last left (its print,
//  once opened), an amber dot on the edited ones, the open one outlined.

import SwiftUI

struct LibraryColumn: View {
    @ObservedObject var model: ProbeModel

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                Text("Library")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(Theme.secondaryText)
                    .textCase(.uppercase)
                    .kerning(0.6)
                Spacer()
                Text(verbatim: "\(model.photos.count)")
                    .font(.footnote.monospacedDigit())
                    .foregroundStyle(Theme.tertiaryText)
            }
            .padding(.horizontal, 12)
            .padding(.top, 12)
            .padding(.bottom, 6)
            ScrollViewReader { proxy in
                ScrollView(.vertical, showsIndicators: false) {
                    LazyVStack(spacing: 12) {
                        ForEach(model.photos) { photo in
                            Button { Task { await model.open(photo) } } label: {
                                LibraryCell(model: model, photo: photo, width: Theme.libraryWidth - 24)
                            }
                            .buttonStyle(.plain)
                            .disabled(model.busy != nil)
                            .id(photo.name)
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                }
                .onAppear { if let name = model.current?.name { proxy.scrollTo(name, anchor: .center) } }
                .onChange(of: model.current) { _, photo in
                    if let photo { withAnimation { proxy.scrollTo(photo.name, anchor: .center) } }
                }
            }
        }
        .background(Theme.rail)
    }
}

/// The iPhone's library, in a sheet: tap a photo to open it.
struct LibraryGrid: View {
    @ObservedObject var model: ProbeModel
    let done: () -> Void

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 104), spacing: 12)], spacing: 14) {
                    ForEach(model.photos) { photo in
                        Button {
                            done()
                            Task { await model.open(photo) }
                        } label: {
                            LibraryCell(model: model, photo: photo, width: 104)
                        }
                        .buttonStyle(.plain)
                        .disabled(model.busy != nil)
                    }
                }
                .padding(16)
            }
            .background(Theme.rail)
            .navigationTitle(Text("Library"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done", action: done) }
            }
        }
        .preferredColorScheme(.dark)
    }
}

struct LibraryCell: View {
    @ObservedObject var model: ProbeModel
    let photo: LibraryPhoto
    let width: CGFloat

    var body: some View {
        let isOpen = model.current == photo
        let isEdited = model.edited.contains(photo.name)
        VStack(alignment: .leading, spacing: 5) {
            ZStack(alignment: .topTrailing) {
                Group {
                    if let image = model.thumbnails[photo.name] {
                        Image(uiImage: image).resizable().scaledToFit()
                    } else {
                        Image(systemName: "photo").font(.title3).foregroundStyle(Theme.tertiaryText)
                    }
                }
                .frame(width: width, height: width * 0.72)
                .background(Theme.ground)
                .clipShape(RoundedRectangle(cornerRadius: 6))
                if isEdited {
                    Circle().fill(Theme.accent).frame(width: 8, height: 8)
                        .overlay(Circle().stroke(Theme.rail, lineWidth: 1.5))
                        .padding(5)
                }
            }
            .overlay(RoundedRectangle(cornerRadius: 7)
                .stroke(isOpen ? Theme.accent : .clear, lineWidth: 2.5)
                .padding(-2))
            Text(verbatim: photo.name)
                .font(.caption2)
                .foregroundStyle(isOpen ? Theme.text : Theme.secondaryText)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(width: width, alignment: .leading)
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: photo.name + (isEdited ? ", " + String(localized: "edited") : "")))
        .accessibilityAddTraits(isOpen ? .isSelected : [])
    }
}
