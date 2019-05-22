//  Created by Laura Skelton on 11/28/16.
//  Copyright © 2016 Airbnb. All rights reserved.

import CoreGraphics
import UIKit

/// A TableView class that handles updates through its `setSections` method, and optionally animates diffs.
open class TableView: UITableView, TypedEpoxyInterface, InternalEpoxyInterface {

  public typealias DataType = InternalTableViewEpoxyData
  public typealias Cell = TableViewCell

  // MARK: Lifecycle

  /// Initializes the TableView
  public init() {
    self.epoxyDataSource = TableViewEpoxyDataSource()
    super.init(frame: .zero, style: .plain)
    setUp()
  }

  public required init?(coder aDecoder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  // MARK: Open

  open override func traitCollectionDidChange(
    _ previousTraitCollection: UITraitCollection?)
  {
    super.traitCollectionDidChange(previousTraitCollection)
    if
      previousTraitCollection?.preferredContentSizeCategory != .unspecified &&
        previousTraitCollection?.preferredContentSizeCategory != traitCollection.preferredContentSizeCategory
    {
      // Dynamic type settings changed so we need to
      // recalculate the heights of every cell.
      // This is done on the next runloop to ensure
      // every view's `traitCollectionDidChange` is called first,
      // which will update the layout properties of those views.
      DispatchQueue.main.async {
        self.recalculateCellHeights()
      }
    }
  }

  // MARK: Public

  public func setSections(_ sections: [EpoxySection]?, animated: Bool) {
    epoxyDataSource.setSections(sections, animated: animated)
  }

  public func scrollToItem(at dataID: String, animated: Bool = false) {
    scrollToItem(at: dataID, scrollPosition: .middle, animated: animated)
  }

  public func scrollToItem(at dataID: String, scrollPosition: UITableView.ScrollPosition, animated: Bool) {
    if let indexPath = epoxyDataSource.internalData?.indexPathForItem(at: dataID) {
      scrollToRow(at: indexPath, at: scrollPosition, animated: animated)
    }
  }

  public func selectItem(at dataID: String, animated: Bool) {
    guard let indexPath = epoxyDataSource.internalData?.indexPathForItem(at: dataID) else {
      assertionFailure("item not found")
      return
    }
    selectRow(at: indexPath, animated: animated, scrollPosition: .none)
    if let cell = cellForRow(at: indexPath) as? EpoxyCell,
      let item = epoxyDataSource.epoxyModel(at: indexPath) {
      item.configure(cell: cell, forTraitCollection: traitCollection, state: .selected)
    }
  }

  public func deselectItem(at dataID: String, animated: Bool) {
    guard let indexPath = epoxyDataSource.internalData?.indexPathForItem(at: dataID) else {
      return
    }
    deselectRow(at: indexPath, animated: animated)

    if let cell = cellForRow(at: indexPath) as? EpoxyCell,
      let item = epoxyDataSource.epoxyModel(at: indexPath) {
      item.configure(cell: cell, forTraitCollection: traitCollection, state: .normal)
    }
  }

  /// Sets a given dataID's view as the first responder. The view must be rendered
  /// at the time this is called, so you should call `scrollToItem(at dataID: String)`
  /// before calling this method if necessary. The view should also be set up to
  /// properly react to `becomeFirstResponder()` being called on it.
  ///
  /// - Parameter dataID: The dataID related to the view you want to becomeFirstResponder
  public func setItemAsFirstResponder(at dataID: String) {
    guard
      let indexPath = epoxyDataSource.internalData?.indexPathForItem(at: dataID),
      let cell = cellForRow(at: indexPath) as? TableViewCell
      else {
        return
    }
    cell.view?.becomeFirstResponder()
  }

  public func moveAccessibilityFocusToItem(
    at dataID: String,
    notification: UIAccessibility.Notification = .layoutChanged)
  {
    guard
      let indexPath = epoxyDataSource.internalData?.indexPathForItem(at: dataID),
      let cell = cellForRow(at: indexPath) as? TableViewCell
      else {
        assertionFailure("item not found")
        return
    }
    UIAccessibility.post(notification: notification, argument: cell)
  }

  public func recalculateCellHeights() {
    beginUpdates()
    endUpdates()
  }

  public func updateItem(
    at dataID: String,
    with item: EpoxyableModel,
    animated: Bool)
  {
    epoxyDataSource.updateItem(at: dataID, with: item, animated: animated)
  }

  /// Returns the userInfo value for a given key from the section at the provided dataID
  public func sectionUserInfoValue<T>(at dataID: String, for key: EpoxyUserInfoKey) -> T? {
    guard let sectionIndex = epoxyDataSource.internalData?.indexForSection(at: dataID) else {
      return nil
    }
    return epoxyDataSource.epoxySection(at: sectionIndex)?.userInfo[key] as? T
  }

  /// Returns the userInfo value for a given key from the model at the provided dataID
  public func itemUserInfoValue<T>(at dataID: String, for key: EpoxyUserInfoKey) -> T? {
    guard let indexPath = epoxyDataSource.internalData?.indexPathForItem(at: dataID) else {
      return nil
    }
    return epoxyDataSource.epoxyModel(at: indexPath)?.userInfo[key] as? T
  }

  /// Delegate for handling `UIScrollViewDelegate` callbacks related to scrolling.
  /// Ignores zooming delegate methods.
  public weak var scrollDelegate: UIScrollViewDelegate?

  /// Delegate which indicates when an epoxy item will be displayed, typically used
  /// for logging.
  public weak var epoxyModelDisplayDelegate: TableViewEpoxyModelDisplayDelegate?

  /// Data source for prefetching the contents of offscreen epoxy items that are likely to come on-
  /// screen soon.
  public weak var epoxyModelPrefetchDataSource: TableViewEpoxyModelDataSourcePrefetching? {
    didSet {
      prefetchDataSource = (epoxyModelPrefetchDataSource != nil) ? self : nil
    }
  }

  /// Delegate for providing swipe actions configuration
  public weak var epoxyModelSwipeActionDelegate: TableViewEpoxyModelSwipeActionDelegate?

  /// Whether to deselect items immediately after they are selected.
  public var autoDeselectItems: Bool = true

  /// Selection color for the `UITableViewCell`s of `EpoxyModel`s that have `isSelectable == true`
  public var selectionStyle = CellSelectionStyle.color(UIColor.lightGray)

  /// Whether or not the final item in the list shows a bottom divider. Defaults to false.
  public var showsLastDivider: Bool = false

  /// Hides the bottom divider for the given dataIDs
  public func hideBottomDivider(for dataIDs: [String]) {
    dataIDsForHidingDividers = dataIDs

    guard isTableViewLaidOut() else {
      // We only want to update the dividers if the table view has completed it's original
      // layout and loading, otherwise we can get unsatisfiable constraint errors in cells.
      return
    }

    indexPathsForVisibleRows?.forEach { indexPath in
      guard let cell = cellForRow(at: indexPath) else {
        return
      }
      guard let epoxyCell = cell as? TableViewCell else {
        assertionFailure("Only TableViewCell and subclasses are allowed in a TableView.")
        return
      }

      if let item = epoxyDataSource.epoxyModel(at: indexPath) {
        self.updateDivider(for: epoxyCell, dividerType: item.dividerType, dataID: item.dataID)
      }
    }
  }

  /// Block that handles the pull to refresh action
  public var didTriggerPullToRefresh: ((UIRefreshControl) -> Void)? {
    didSet {
      pullToRefreshEnabled = didTriggerPullToRefresh != nil
    }
  }

  /// Pull to refresh control
  public lazy var pullToRefreshControl: UIRefreshControl = {
    let refreshControl = UIRefreshControl()
    refreshControl.addTarget(self, action: #selector(didTriggerPullToRefreshControl(sender:)), for: .valueChanged)
    return refreshControl
  }()

  /// Whether or not pull to refresh is enabled
  public var pullToRefreshEnabled: Bool = false {
    didSet {
      // TODO: Once we drop iOS 9, set UIScrollView's refreshControl directly
      if pullToRefreshEnabled {
        addSubview(pullToRefreshControl)
      } else {
        pullToRefreshControl.removeFromSuperview()
      }
    }
  }

  /// Block that should return an initialized view of the type you'd like to use for this divider.
  public var rowDividerBuilder: (() -> UIView)?

  /// Block that configures the divider.
  public var rowDividerConfigurer: ((UIView) -> Void)?

  /// Block that should return an initialized view of the type you'd like to use for this divider.
  public var sectionHeaderDividerBuilder: (() -> UIView)?

  /// Block that configures this divider.
  public var sectionHeaderDividerConfigurer: ((UIView) -> Void)?

  public var visibleIndexPaths: [IndexPath] {
    return indexPathsForVisibleRows ?? []
  }

  public func register(cellReuseID: String) {
    super.register(
      TableViewCell.self,
      forCellReuseIdentifier: cellReuseID)
  }

  public func register(supplementaryViewReuseID: String, forKind elementKind: String) {
    super.register(
      TableViewCell.self,
      forCellReuseIdentifier: supplementaryViewReuseID)
  }

  public func configure(cell: Cell, with item: EpoxyModelWrapper) {
    configure(cell: cell, with: item, animated: false)

    let cellSelectionStyle = item.selectionStyle ?? selectionStyle
    switch cellSelectionStyle {
    case .noBackground:
      cell.selectedBackgroundColor = nil
    case .color(let selectionColor):
      cell.selectedBackgroundColor = selectionColor
    }
  }

  public func reloadItem(at indexPath: IndexPath, animated: Bool) {
    if let cell = cellForRow(at: indexPath as IndexPath) as? TableViewCell,
      let item = epoxyDataSource.epoxyModel(at: indexPath) {
      configure(cell: cell, with: item, animated: animated)
    }
  }

  public func apply(
    _ newData: DataType?,
    animated: Bool,
    changesetMaker: @escaping (DataType?) -> EpoxyChangeset?)
  {
    guard animated,
      newData != nil,
      let sectionCount = dataSource?.numberOfSections?(in: self),
      sectionCount > 0
      else {
        _ = changesetMaker(newData)
        reloadData()
        return
    }

    beginUpdates()

    if let changeset = changesetMaker(newData) {
      changeset.itemChangeset.updates.forEach { fromIndexPath, toIndexPath in
        if let cell = cellForRow(at: fromIndexPath as IndexPath) as? TableViewCell,
          let epoxyModel = epoxyDataSource.epoxyModel(at: toIndexPath)?.epoxyModel {
          epoxyModel.configure(cell: cell, forTraitCollection: traitCollection, animated: true)
          epoxyModel.configure(cell: cell, forTraitCollection: traitCollection, state: cell.state)
        }
      }

      // TODO(ls): Make animations configurable
      deleteRows(at: changeset.itemChangeset.deletes as [IndexPath], with: .fade)
      deleteSections(changeset.sectionChangeset.deletes as IndexSet, with: .fade)

      insertRows(at: changeset.itemChangeset.inserts, with: .fade)
      insertSections(changeset.sectionChangeset.inserts as IndexSet, with: .fade)

      changeset.sectionChangeset.moves.forEach { fromIndex, toIndex in
        moveSection(fromIndex, toSection: toIndex)
      }

      changeset.itemChangeset.moves.forEach { fromIndexPath, toIndexPath in
        moveRow(at: fromIndexPath, to: toIndexPath)
      }
    }

    endUpdates()

    indexPathsForVisibleRows?.forEach { indexPath in
      guard let cell = cellForRow(at: indexPath) else {
        return
      }
      guard let epoxyCell = cell as? TableViewCell else {
        assertionFailure("Only TableViewCell and subclasses are allowed in a TableView.")
        return
      }

      if let item = epoxyDataSource.epoxyModel(at: indexPath) {
        item.setBehavior(cell: epoxyCell)
        self.updateDivider(for: epoxyCell, dividerType: item.dividerType, dataID: item.dataID)
      }
    }
  }

  public func addInfiniteScrolling<LoaderView>(
    delegate: InfiniteScrollingDelegate,
    loaderView: LoaderView)
    where LoaderView: UIView, LoaderView: Animatable
  {
    let height = loaderView.compressedHeight(forWidth: bounds.width)
    loaderView.translatesAutoresizingMaskIntoConstraints = true
    loaderView.frame.size.height = height
    tableFooterView = loaderView

    loaderView.stopAnimating()
    infiniteScrollingLoader = loaderView
    infiniteScrollingDelegate = delegate
  }

  public func removeInfiniteScrolling() {
    tableFooterView = nil
    infiniteScrollingLoader = nil
    infiniteScrollingDelegate = nil
  }

  // MARK: Fileprivate

  fileprivate let epoxyDataSource: TableViewEpoxyDataSource

  fileprivate weak var infiniteScrollingDelegate: InfiniteScrollingDelegate?
  fileprivate var infiniteScrollingState: InfiniteScrollingState = .stopped
  fileprivate var infiniteScrollingLoader: Animatable?

  fileprivate func updatedInfiniteScrollingState(in scrollView: UIScrollView) -> (InfiniteScrollingState, Bool) {
    let previousState = infiniteScrollingState
    let newState = previousState.next(in: scrollView)
    return (newState, previousState == .triggered && newState == .loading)
  }

  // MARK: Private

  private var dataIDsForHidingDividers = [String]()
  private var ephemeralStateCache = [String: RestorableState?]()

  private func setUp() {
    delegate = self
    epoxyDataSource.epoxyInterface = self
    dataSource = epoxyDataSource
    rowHeight = UITableView.automaticDimension
    estimatedRowHeight = 44 // TODO(ls): Use better estimated height
    separatorStyle = .none
    backgroundColor = .clear
    translatesAutoresizingMaskIntoConstraints = false
    cellLayoutMarginsFollowReadableWidth = false
  }

  private func configure(cell: Cell, with item: EpoxyModelWrapper, animated: Bool) {
    item.configure(cell: cell, forTraitCollection: traitCollection, animated: animated)
    item.setBehavior(cell: cell)
    updateDivider(for: cell, dividerType: item.dividerType, dataID: item.dataID)
    if item.isSelectable {
      cell.accessibilityTraits = [cell.accessibilityTraits, .button]
    }

    cell.cachedEphemeralState = ephemeralStateCache[item.dataID] ?? nil
    cell.ephemeralViewCachedStateProvider = { [weak self] state in
      self?.ephemeralStateCache[item.dataID] = state
    }
  }

  private func updateDivider(for cell: TableViewCell, dividerType: EpoxyModelDividerType, dataID: String?) {
    if let dataID = dataID,
      dataIDsForHidingDividers.contains(dataID)
    {
      cell.dividerView?.isHidden = true
      return
    }
    switch dividerType {
    case .none:
      if !showsLastDivider {
        cell.dividerView?.isHidden = true
      } else {
        configureCellWithRowDivider(cell: cell)
      }
    case .rowDivider:
      configureCellWithRowDivider(cell: cell)
    case .sectionHeaderDivider:
      configureCellWithSectionHeaderDivider(cell: cell)
    }
  }

  private func configureCellWithRowDivider(cell: TableViewCell) {
    if let rowDividerBuilder = rowDividerBuilder {
      cell.dividerView?.isHidden = false
      cell.makeDividerViewIfNeeded(with: rowDividerBuilder)
      if let divider = cell.dividerView {
        rowDividerConfigurer?(divider)
      }
    } else {
      cell.dividerView?.isHidden = true
    }
  }

  private func configureCellWithSectionHeaderDivider(cell: TableViewCell) {
    if let sectionHeaderDividerBuilder = sectionHeaderDividerBuilder {
      cell.dividerView?.isHidden = false
      cell.makeDividerViewIfNeeded(with: sectionHeaderDividerBuilder)
      if let divider = cell.dividerView {
        sectionHeaderDividerConfigurer?(divider)
      }
    } else {
      cell.dividerView?.isHidden = true
    }
  }

  private func isTableViewLaidOut() -> Bool {
    return frame.size.width > 0 && frame.size.height > 0
  }

  @objc
  private func didTriggerPullToRefreshControl(sender: UIRefreshControl) {
    didTriggerPullToRefresh?(sender)
  }
}

// MARK: UITableViewDelegate

extension TableView: UITableViewDelegate {

  public func tableView(
    _ tableView: UITableView,
    willDisplay cell: UITableViewCell,
    forRowAt indexPath: IndexPath)
  {
    guard
      let item = epoxyDataSource.epoxyModel(at: indexPath),
      let section = epoxyDataSource.epoxySection(at: indexPath.section) else
    {
      return
    }
    item.willDisplay()
    epoxyModelDisplayDelegate?.tableView(self, willDisplay: item, in: section)
  }

  public func tableView(
    _ tableView: UITableView,
    didEndDisplaying cell: UITableViewCell,
    forRowAt indexPath: IndexPath)
  {
    guard
      let item = epoxyDataSource.epoxyModel(at: indexPath),
      let section = epoxyDataSource.epoxySection(at: indexPath.section) else
    {
      return
    }

    item.didEndDisplaying()
    epoxyModelDisplayDelegate?.tableView(self, didEndDisplaying: item, in: section)
  }

  public func tableView(
    _ tableView: UITableView,
    shouldHighlightRowAt indexPath: IndexPath) -> Bool
  {
    guard let item = epoxyDataSource.epoxyModel(at: indexPath) else {
      assertionFailure("Index path is out of bounds")
      return false
    }
    return item.isSelectable
  }

  public func tableView(
    _ tableView: UITableView,
    didHighlightRowAt indexPath: IndexPath)
  {
    guard let item = epoxyDataSource.epoxyModel(at: indexPath),
      let cell = tableView.cellForRow(at: indexPath) as? TableViewCell else {
      assertionFailure("Index path is out of bounds")
      return
    }
    item.configure(cell: cell, forTraitCollection: traitCollection, state: .highlighted)
  }

  public func tableView(
    _ tableView: UITableView,
    didUnhighlightRowAt indexPath: IndexPath)
  {
    guard let item = epoxyDataSource.epoxyModel(at: indexPath),
      let cell = tableView.cellForRow(at: indexPath) as? TableViewCell else {
        return
    }
    item.configure(cell: cell, forTraitCollection: traitCollection, state: .normal)
  }

  public func tableView(
    _ tableView: UITableView,
    willSelectRowAt indexPath: IndexPath) -> IndexPath?
  {
    guard let item = epoxyDataSource.epoxyModel(at: indexPath) else {
      assertionFailure("Index path is out of bounds")
      return nil
    }
    return item.isSelectable ? indexPath : nil
  }

  public func tableView(
    _ tableView: UITableView,
    didSelectRowAt indexPath: IndexPath)
  {
    guard let item = epoxyDataSource.epoxyModel(at: indexPath),
      let cell = tableView.cellForRow(at: indexPath) as? TableViewCell else {
      assertionFailure("Index path is out of bounds")
      return
    }
    item.configure(cell: cell, forTraitCollection: traitCollection, state: .selected)
    item.didSelect(cell)

    if autoDeselectItems {
      // If tableView modifications have been made, indexPath may no longer point to the correct
      // row so we find the all currently selected rows and deselect them.
      // In practice this should always be a single row
      if let selectedIndexPaths = tableView.indexPathsForSelectedRows {
        selectedIndexPaths.forEach { tableView.deselectRow(at: $0, animated: true) }
      }
      _ = item.configure(cell: cell, forTraitCollection: traitCollection, state: .normal)
    }
  }

  public func tableView(
    _ tableView: UITableView,
    willDeselectRowAt indexPath: IndexPath) -> IndexPath?
  {
    guard let item = epoxyDataSource.epoxyModel(at: indexPath) else {
      assertionFailure("Index path is out of bounds")
      return nil
    }
    return item.isSelectable ? indexPath : nil
  }

  public func tableView(
    _ tableView: UITableView,
    didDeselectRowAt indexPath: IndexPath)
  {
    guard let item = epoxyDataSource.epoxyModel(at: indexPath),
      let cell = tableView.cellForRow(at: indexPath) as? TableViewCell else {
        return
    }

    item.configure(cell: cell, forTraitCollection: traitCollection, state: .normal)
  }

  @available(iOS 11.0, *)
  public func tableView(
    _ tableView: UITableView,
    leadingSwipeActionsConfigurationForRowAt indexPath: IndexPath) -> UISwipeActionsConfiguration?
  {
    guard
      let item = epoxyDataSource.epoxyModel(at: indexPath),
      let section = epoxyDataSource.epoxySection(at: indexPath.section) else
    { return nil }

    return epoxyModelSwipeActionDelegate?.tableView(
      self,
      leadingSwipeActionsConfigurationForModel: item,
      in: section)
  }

  @available(iOS 11.0, *)
  public func tableView(
    _ tableView: UITableView,
    trailingSwipeActionsConfigurationForRowAt indexPath: IndexPath) -> UISwipeActionsConfiguration?
  {
    guard
      let item = epoxyDataSource.epoxyModel(at: indexPath),
      let section = epoxyDataSource.epoxySection(at: indexPath.section) else
    { return nil }

    return epoxyModelSwipeActionDelegate?.tableView(
      self,
      trailingSwipeActionsConfigurationForModel: item,
      in: section)
  }

  public func tableView(
    _ tableView: UITableView,
    editingStyleForRowAt indexPath: IndexPath) -> UITableViewCell.EditingStyle
  {
    guard
      let item = epoxyDataSource.epoxyModel(at: indexPath),
      let section = epoxyDataSource.epoxySection(at: indexPath.section),
      let delegate = epoxyModelSwipeActionDelegate else
    { return .none }

    return delegate.tableView(self, editingStyleForModel: item, in: section)
  }

  public func scrollViewDidScroll(_ scrollView: UIScrollView) {
    scrollDelegate?.scrollViewDidScroll?(scrollView)
    let (newState, shouldTrigger) = updatedInfiniteScrollingState(in: scrollView)
    infiniteScrollingState = newState
    let delegateWantsInfiniteScrolling = infiniteScrollingDelegate?.shouldFireInfiniteScrolling() ?? true
    if shouldTrigger && delegateWantsInfiniteScrolling {
      infiniteScrollingLoader?.startAnimating()
      infiniteScrollingDelegate?.didScrollToInfiniteLoader { [weak self] in
        self?.infiniteScrollingLoader?.stopAnimating()
        self?.infiniteScrollingState = .stopped
      }
    } else if !delegateWantsInfiniteScrolling {
      infiniteScrollingState = .stopped
    }
  }

  public func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
    scrollDelegate?.scrollViewWillBeginDragging?(scrollView)
  }

  public func scrollViewWillEndDragging(
    _ scrollView: UIScrollView, withVelocity
    velocity: CGPoint,
    targetContentOffset: UnsafeMutablePointer<CGPoint>)
  {
    scrollDelegate?.scrollViewWillEndDragging?(scrollView, withVelocity: velocity, targetContentOffset: targetContentOffset)
  }

  public func scrollViewDidEndDragging(
    _ scrollView: UIScrollView, willDecelerate
    decelerate: Bool)
  {
    scrollDelegate?.scrollViewDidEndDragging?(scrollView, willDecelerate: decelerate)
  }

  public func scrollViewShouldScrollToTop(_ scrollView: UIScrollView) -> Bool {
    return scrollDelegate?.scrollViewShouldScrollToTop?(scrollView) ?? true
  }

  public func scrollViewDidScrollToTop(_ scrollView: UIScrollView) {
    scrollDelegate?.scrollViewDidScrollToTop?(scrollView)
  }

  public func scrollViewWillBeginDecelerating(_ scrollView: UIScrollView) {
    scrollDelegate?.scrollViewWillBeginDecelerating?(scrollView)
  }

  public func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) {
    scrollDelegate?.scrollViewDidEndDecelerating?(scrollView)
  }

  public func scrollViewDidEndScrollingAnimation(_ scrollView: UIScrollView) {
    scrollDelegate?.scrollViewDidEndScrollingAnimation?(scrollView)
  }
}

// MARK: UITableViewDataSourcePrefetching

extension TableView: UITableViewDataSourcePrefetching {
  public func tableView(_ tableView: UITableView, prefetchRowsAt indexPaths: [IndexPath]) {
    let models = indexPaths.compactMap(epoxyDataSource.epoxyModel(at:))
      .map { $0.epoxyModel }

    guard !models.isEmpty else {
      return
    }

    epoxyModelPrefetchDataSource?.tableView(self, prefetch: models)
  }

  public func tableView(_ tableView: UITableView, cancelPrefetchingForRowsAt indexPaths: [IndexPath]) {
    let models = indexPaths.compactMap(epoxyDataSource.epoxyModel(at:))
      .map { $0.epoxyModel }

    guard !models.isEmpty else {
      return
    }

    epoxyModelPrefetchDataSource?.tableView(self, cancelPrefetchingOf: models)
  }
}

// MARK: Unavailable Methods

extension TableView {

  @available (*, unavailable, message: "You shouldn't be registering cell classes on a TableView. The TableViewEpoxyDataSource handles this for you.")
  open override func register(_ cellClass: AnyClass?, forCellReuseIdentifier identifier: String) {
    super.register(cellClass, forCellReuseIdentifier: identifier)
  }

  @available (*, unavailable, message: "You shouldn't be registering cell nibs on a TableView. The TableViewEpoxyDataSource handles this for you.")
  open override func register(_ nib: UINib?, forCellReuseIdentifier identifier: String) {
    super.register(nib, forCellReuseIdentifier: identifier)
  }

  @available (*, unavailable, message: "You shouldn't be header or footer nibs on a TableView. The TableViewEpoxyDataSource handles this for you.")
  open override func register(_ nib: UINib?, forHeaderFooterViewReuseIdentifier identifier: String) {
    super.register(nib, forHeaderFooterViewReuseIdentifier: identifier)
  }

  @available (*, unavailable, message: "You shouldn't be registering header or footer classes on a TableView. The TableViewEpoxyDataSource handles this for you.")
  open override func register(_ aClass: AnyClass?, forHeaderFooterViewReuseIdentifier identifier: String) {
    super.register(aClass, forHeaderFooterViewReuseIdentifier: identifier)
  }

}