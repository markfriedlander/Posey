import SwiftUI
import UIKit

// ========== BLOCK 01: ZOOMABLE SCROLL VIEW - START ==========

/// UIScrollView subclass that owns and sizes its image view.
/// Handles layout in `layoutSubviews` so the image fills the available
/// bounds correctly even when the SwiftUI hosting container resizes.
final class ZoomScrollView: UIScrollView {
    let imageView: UIImageView

    init(image: UIImage) {
        imageView = UIImageView(image: image)
        imageView.contentMode = .scaleAspectFit
        imageView.isUserInteractionEnabled = false
        super.init(frame: .zero)
        minimumZoomScale = 1.0
        maximumZoomScale = 6.0
        showsHorizontalScrollIndicator = false
        showsVerticalScrollIndicator = false
        backgroundColor = .black
        bouncesZoom = true
        addSubview(imageView)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layoutSubviews() {
        super.layoutSubviews()
        let size = bounds.size
        guard size.width > 0, size.height > 0, zoomScale == minimumZoomScale else { return }
        imageView.frame = CGRect(origin: .zero, size: size)
        contentSize = size
    }
}

// ========== BLOCK 01: ZOOMABLE SCROLL VIEW - END ==========

// ========== BLOCK 02: ZOOMABLE IMAGE VIEW REPRESENTABLE - START ==========

/// UIScrollView-backed view with pinch-to-zoom and double-tap-to-zoom.
/// Intended for full-screen presentation of PDF visual pages.
struct ZoomableImageView: UIViewRepresentable {
    let image: UIImage

    func makeUIView(context: Context) -> ZoomScrollView {
        let scrollView = ZoomScrollView(image: image)
        scrollView.delegate = context.coordinator

        let doubleTap = UITapGestureRecognizer(
            target: context.coordinator,
            action: #selector(Coordinator.handleDoubleTap(_:))
        )
        doubleTap.numberOfTapsRequired = 2
        scrollView.addGestureRecognizer(doubleTap)

        return scrollView
    }

    func updateUIView(_ scrollView: ZoomScrollView, context: Context) {
        scrollView.imageView.image = image
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator: NSObject, UIScrollViewDelegate {
        func viewForZooming(in scrollView: UIScrollView) -> UIView? {
            (scrollView as? ZoomScrollView)?.imageView
        }

        /// Keep the image centered while zoomed.
        func scrollViewDidZoom(_ scrollView: UIScrollView) {
            guard let imageView = (scrollView as? ZoomScrollView)?.imageView else { return }
            let bounds = scrollView.bounds
            let cx = max(imageView.frame.width,  bounds.width)  / 2
            let cy = max(imageView.frame.height, bounds.height) / 2
            imageView.center = CGPoint(x: cx, y: cy)
        }

        @objc func handleDoubleTap(_ gesture: UITapGestureRecognizer) {
            guard let scrollView = gesture.view as? ZoomScrollView else { return }
            if scrollView.zoomScale > scrollView.minimumZoomScale {
                scrollView.setZoomScale(scrollView.minimumZoomScale, animated: true)
            } else {
                let location = gesture.location(in: scrollView.imageView)
                let rect = CGRect(x: location.x - 50, y: location.y - 50, width: 100, height: 100)
                scrollView.zoom(to: rect, animated: true)
            }
        }
    }
}

// ========== BLOCK 02: ZOOMABLE IMAGE VIEW REPRESENTABLE - END ==========
