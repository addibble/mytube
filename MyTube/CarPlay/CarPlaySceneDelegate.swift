import CarPlay
import Observation
import UIKit

/// CarPlay: a list of audiobooks that resume on tap, plus the system Now Playing screen.
final class CarPlaySceneDelegate: UIResponder, CPTemplateApplicationSceneDelegate {
    private var interfaceController: CPInterfaceController?
    private let listTemplate = CPListTemplate(title: "Audiobooks", sections: [])

    func templateApplicationScene(
        _ templateApplicationScene: CPTemplateApplicationScene,
        didConnect interfaceController: CPInterfaceController
    ) {
        self.interfaceController = interfaceController
        listTemplate.emptyViewTitleVariants = ["No Audiobooks"]
        listTemplate.emptyViewSubtitleVariants = ["Add a book in MyTube on your iPhone."]
        interfaceController.setRootTemplate(listTemplate, animated: false, completion: nil)
        refresh()
    }

    func templateApplicationScene(
        _ templateApplicationScene: CPTemplateApplicationScene,
        didDisconnectInterfaceController interfaceController: CPInterfaceController
    ) {
        self.interfaceController = nil
    }

    /// Rebuilds the list and Now Playing buttons, and again whenever the data they show changes.
    private func refresh() {
        guard interfaceController != nil else { return }
        withObservationTracking {
            updateList()
            updateNowPlayingButtons()
        } onChange: { [weak self] in
            Task { @MainActor in self?.refresh() }
        }
    }

    private func updateList() {
        let player = PlayerEngine.shared
        let items = Library.shared.books.map { book -> CPListItem in
            let part = book.currentPart
            var detail = book.author
            if let part, book.parts.count > 1 {
                detail += (detail.isEmpty ? "" : " · ") + part.title
            }
            let item = CPListItem(text: book.title, detailText: detail)
            item.isPlaying = player.bookID == book.id && player.isPlaying
            item.playbackProgress = book.progress
            if let videoID = part?.videoID {
                if let image = ArtworkCache.shared.cached(videoID) {
                    item.setImage(image)
                } else {
                    Task { @MainActor [weak item] in
                        guard let image = await ArtworkCache.shared.image(for: videoID) else { return }
                        item?.setImage(image)
                    }
                }
            }
            item.handler = { [weak self] _, completion in
                PlayerEngine.shared.play(bookID: book.id)
                self?.showNowPlaying()
                completion()
            }
            return item
        }
        listTemplate.updateSections([CPListSection(items: items)])
    }

    private func showNowPlaying() {
        guard let interfaceController, interfaceController.topTemplate !== CPNowPlayingTemplate.shared else { return }
        interfaceController.pushTemplate(CPNowPlayingTemplate.shared, animated: true, completion: nil)
    }

    /// The transport row shows the preferred skip intervals; these add the other 15/30 choice and speed.
    private func updateNowPlayingButtons() {
        let player = PlayerEngine.shared
        var buttons: [CPNowPlayingButton] = []

        let otherBack = PlayerEngine.skipChoices.first { $0 != player.skipBackInterval }
        if let otherBack, let image = UIImage(systemName: "gobackward.\(otherBack)") {
            buttons.append(CPNowPlayingImageButton(image: image) { _ in
                PlayerEngine.shared.skip(-TimeInterval(otherBack))
            })
        }
        buttons.append(CPNowPlayingPlaybackRateButton { _ in
            let player = PlayerEngine.shared
            let index = PlayerEngine.rates.firstIndex(of: player.rate) ?? 0
            player.setRate(PlayerEngine.rates[(index + 1) % PlayerEngine.rates.count])
        })
        let otherForward = PlayerEngine.skipChoices.first { $0 != player.skipForwardInterval }
        if let otherForward, let image = UIImage(systemName: "goforward.\(otherForward)") {
            buttons.append(CPNowPlayingImageButton(image: image) { _ in
                PlayerEngine.shared.skip(TimeInterval(otherForward))
            })
        }

        let template = CPNowPlayingTemplate.shared
        template.isUpNextButtonEnabled = false
        template.isAlbumArtistButtonEnabled = false
        template.updateNowPlayingButtons(buttons)
    }
}
