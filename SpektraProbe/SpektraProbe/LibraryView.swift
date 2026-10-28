//  LibraryView.swift — the library: a column beside the picture on an iPad, a
//  grid in a sheet on an iPhone. Each photo as it was last left (its print,
//  once opened), an amber dot on the edited ones, the open one outlined.
//
//  Organising (the model's side is `Library.swift` and ProbeModel):
//  - a star: filled amber on a favourite, tap to take it off; an outline on
//    the open photo, tap to make it one (any photo: hold › Favourite);
//  - a sort menu in the header: name, date taken, favourites first, or the
//    order a person dragged;
//  - hold a photo for Favourite and Delete…, which asks first;
//  - hold and drag a photo onto another to put it in that one's place.
//  None of it works while the app is busy (opening, exporting).

import SwiftUI

struct LibraryColumn: View {
    @ObservedObject var model: ProbeModel
    @State private var pendingDelete: LibraryPhoto?

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .center, spacing: 4) {
                Text("Library")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(Theme.secondaryText)
                    .textCase(.uppercase)
                    .kerning(0.6)
                    .lineLimit(1)
                    .fixedSize()
                Text(verbatim: "\(model.photos.count)")
                    .font(.footnote.monospacedDigit())
                    .foregroundStyle(Theme.tertiaryText)
                    .fixedSize()
                Spacer(minLength: 0)
                LibrarySortMenu(model: model)
            }
            .padding(.leading, 12)
            .padding(.trailing, 2)
            .padding(.top, 6)
            ScrollViewReader { proxy in
                ScrollView(.vertical, showsIndicators: false) {
                    LazyVStack(spacing: 12) {
                        ForEach(model.photos) { photo in
                            LibraryItem(model: model, photo: photo, width: Theme.libraryWidth - 24,
                                        pendingDelete: $pendingDelete) {
                                Task { await model.open(photo) }
                            }
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
        .libraryDeleteConfirmation(model: model, pendingDelete: $pendingDelete)
    }
}

/// The iPhone's library, in a sheet: tap a photo to open it.
struct LibraryGrid: View {
    @ObservedObject var model: ProbeModel
    let done: () -> Void
    @State private var pendingDelete: LibraryPhoto?

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 104), spacing: 12)], spacing: 14) {
                    ForEach(model.photos) { photo in
                        LibraryItem(model: model, photo: photo, width: 104, pendingDelete: $pendingDelete) {
                            done()
                            Task { await model.open(photo) }
                        }
                    }
                }
                .padding(16)
            }
            .background(Theme.rail)
            .navigationTitle(Text("Library"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { LibrarySortMenu(model: model) }
                ToolbarItem(placement: .confirmationAction) { Button("Done", action: done) }
            }
        }
        .preferredColorScheme(.dark)
        .libraryDeleteConfirmation(model: model, pendingDelete: $pendingDelete)
    }
}

/// How the library is ordered, as a menu behind one icon.
struct LibrarySortMenu: View {
    @ObservedObject var model: ProbeModel

    var body: some View {
        Menu {
            Picker("Sort", selection: Binding(get: { model.librarySort }, set: { model.setLibrarySort($0) })) {
                ForEach(LibrarySort.allCases) { Text(verbatim: $0.title).tag($0) }
            }
        } label: {
            Image(systemName: "arrow.up.arrow.down")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(Theme.secondaryText)
                .frame(width: 30, height: 36)
                .contentShape(Rectangle())
        }
        .accessibilityLabel(Text("Sort"))
        .disabled(model.busy != nil)
    }
}

/// One photo in the library, with everything a finger can do to it: tap to
/// open, the star, hold for the menu, hold and drag to move it.
struct LibraryItem: View {
    @ObservedObject var model: ProbeModel
    let photo: LibraryPhoto
    let width: CGFloat
    @Binding var pendingDelete: LibraryPhoto?
    let open: () -> Void

    var body: some View {
        let favourite = model.isFavorite(photo)
        let isOpen = model.current == photo
        let idle = model.busy == nil
        Button(action: open) {
            LibraryCell(model: model, photo: photo, width: width)
        }
        .buttonStyle(.plain)
        .disabled(!idle)
        // The star is its own button, over the thumbnail rather than inside
        // the cell's, so a tap on it does not open the photo.
        .overlay(alignment: .topLeading) {
            if favourite || isOpen {
                Button {
                    model.toggleFavorite(photo)
                } label: {
                    Image(systemName: favourite ? "star.fill" : "star")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(favourite ? Theme.accent : Theme.text)
                        .frame(width: 22, height: 22)
                        .background(Theme.rail.opacity(0.7), in: Circle())
                        .padding(3)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(!idle)
                .accessibilityLabel(favourite ? Text("Remove from favourites") : Text("Favourite"))
            }
        }
        .contextMenu {
            Button {
                model.toggleFavorite(photo)
            } label: {
                favourite ? Label("Remove from favourites", systemImage: "star.slash")
                          : Label("Favourite", systemImage: "star")
            }
            .disabled(!idle)
            Button(role: .destructive) {
                pendingDelete = photo
            } label: {
                Label("Delete…", systemImage: "trash")
            }
            .disabled(!idle)
        }
        .draggable(photo.name) {
            LibraryCell(model: model, photo: photo, width: width).opacity(0.9)
        }
        .dropDestination(for: String.self) { names, _ in
            guard idle, let name = names.first, name != photo.name,
                  model.photos.contains(where: { $0.name == name }) else { return false }
            withAnimation(.snappy(duration: 0.25)) { model.movePhoto(name, to: photo.name) }
            return true
        }
    }
}

extension View {
    /// "Delete “L1000049.DNG”?" before a photo leaves the library.
    func libraryDeleteConfirmation(model: ProbeModel, pendingDelete: Binding<LibraryPhoto?>) -> some View {
        confirmationDialog(Text("Delete “\(pendingDelete.wrappedValue?.name ?? "")”?"),
                           isPresented: Binding(get: { pendingDelete.wrappedValue != nil },
                                                set: { if !$0 { pendingDelete.wrappedValue = nil } }),
                           titleVisibility: .visible,
                           presenting: pendingDelete.wrappedValue) { photo in
            Button("Delete", role: .destructive) { Task { await model.delete(photo) } }
        } message: { _ in
            Text("The photo and its edits leave RA4's library. Exports stay, and so does the original in Photos or Files.")
        }
    }
}

struct LibraryCell: View {
    @ObservedObject var model: ProbeModel
    let photo: LibraryPhoto
    let width: CGFloat

    var body: some View {
        let isOpen = model.current == photo
        let isEdited = model.edited.contains(photo.name)
        let isFavourite = model.isFavorite(photo)
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
        .accessibilityLabel(Text(verbatim: photo.name
                                 + (isFavourite ? ", " + String(localized: "favourite") : "")
                                 + (isEdited ? ", " + String(localized: "edited") : "")))
        .accessibilityAddTraits(isOpen ? .isSelected : [])
    }
}
