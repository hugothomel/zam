import SwiftUI
import UIKit

/// UIPageViewController wrapper for vertical TikTok-style swiping.
/// Built-in scroll is disabled. Page changes are driven by swipe callbacks
/// from PlayerView (bottom zone only), keeping game taps instant everywhere.
struct FeedPageView: UIViewControllerRepresentable {
    let orchestrator: FeedOrchestrator

    func makeUIViewController(context: Context) -> UIPageViewController {
        let pvc = UIPageViewController(
            transitionStyle: .scroll,
            navigationOrientation: .vertical,
            options: [.interPageSpacing: 0]
        )
        pvc.dataSource = context.coordinator
        pvc.delegate = context.coordinator
        pvc.view.backgroundColor = .black

        // Disable the built-in scroll gesture — we drive transitions programmatically
        for subview in pvc.view.subviews {
            if let scrollView = subview as? UIScrollView {
                scrollView.isScrollEnabled = false
            }
        }

        context.coordinator.pageViewController = pvc

        // Set initial page
        let initial = context.coordinator.viewController(at: 0)
        pvc.setViewControllers([initial], direction: .forward, animated: false)

        DispatchQueue.main.async {
            orchestrator.bootstrap()
        }

        return pvc
    }

    func updateUIViewController(_ uiViewController: UIPageViewController, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(orchestrator: orchestrator)
    }

    // MARK: - Coordinator

    final class Coordinator: NSObject, UIPageViewControllerDataSource, UIPageViewControllerDelegate {
        let orchestrator: FeedOrchestrator
        weak var pageViewController: UIPageViewController?
        private var hostingControllers: [Int: UIHostingController<GamePageView>] = [:]
        private var isTransitioning = false

        init(orchestrator: FeedOrchestrator) {
            self.orchestrator = orchestrator
        }

        func viewController(at index: Int) -> UIViewController {
            guard index >= 0 && index < orchestrator.pageCount else {
                return hostingControllers[0] ?? UIViewController()
            }
            if let existing = hostingControllers[index] {
                return existing
            }
            let page = orchestrator.pages[index]
            let view = GamePageView(
                viewModel: page,
                pageIndex: index,
                totalPages: orchestrator.pageCount,
                onSwipeUp: { [weak self] in self?.goToNext() },
                onSwipeDown: { [weak self] in self?.goToPrevious() }
            )
            let hc = UIHostingController(rootView: view)
            hc.view.backgroundColor = .black
            hc.view.tag = index
            hostingControllers[index] = hc
            return hc
        }

        private func index(of viewController: UIViewController) -> Int {
            viewController.view.tag
        }

        // MARK: - Programmatic Navigation

        func goToNext() {
            guard !isTransitioning else { return }
            let nextIndex = (orchestrator.currentIndex + 1) % orchestrator.pageCount
            navigateTo(index: nextIndex, direction: .forward)
        }

        func goToPrevious() {
            guard !isTransitioning else { return }
            let prevIndex = (orchestrator.currentIndex - 1 + orchestrator.pageCount) % orchestrator.pageCount
            navigateTo(index: prevIndex, direction: .reverse)
        }

        private func navigateTo(index: Int, direction: UIPageViewController.NavigationDirection) {
            guard let pvc = pageViewController else { return }
            isTransitioning = true
            let vc = viewController(at: index)
            pvc.setViewControllers([vc], direction: direction, animated: true) { [weak self] _ in
                self?.isTransitioning = false
                self?.orchestrator.didNavigate(to: index)
            }
        }

        // MARK: - UIPageViewControllerDataSource

        func pageViewController(
            _ pageViewController: UIPageViewController,
            viewControllerBefore viewController: UIViewController
        ) -> UIViewController? {
            let idx = index(of: viewController)
            guard idx > 0 else { return nil }
            return self.viewController(at: idx - 1)
        }

        func pageViewController(
            _ pageViewController: UIPageViewController,
            viewControllerAfter viewController: UIViewController
        ) -> UIViewController? {
            let idx = index(of: viewController)
            guard idx < orchestrator.pageCount - 1 else { return nil }
            return self.viewController(at: idx + 1)
        }

        // MARK: - UIPageViewControllerDelegate

        func pageViewController(
            _ pageViewController: UIPageViewController,
            didFinishAnimating finished: Bool,
            previousViewControllers: [UIViewController],
            transitionCompleted completed: Bool
        ) {
            guard completed,
                  let current = pageViewController.viewControllers?.first else { return }
            let idx = index(of: current)
            orchestrator.didNavigate(to: idx)
        }
    }
}
