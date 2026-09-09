"""Local image navigation in source units per Qt logical pixel.

One camera update carries both axes. Stock axis links must not be combined
with these groups: aspect correction between separate X/Y updates can zoom
the follower while the user is only panning. All panes in a window share its
device pixel ratio; logical pixels also match Qt's pointer/scroll coordinates.
"""

from __future__ import annotations

import math

import pyqtgraph as pg
from PySide6 import QtCore, QtGui


class ImageViewBox(pg.ViewBox):
    viewportResized = QtCore.Signal(object)

    def __init__(self, **kwargs):
        self.resizing = False
        super().__init__(lockAspect=True, **kwargs)

    def resizeEvent(self, event):
        self.resizing = True
        try:
            # Qt can deliver a delayed window-manager resize during a drag.
            # Do not publish ViewBox's temporary aspect-corrected range before
            # the group has reapplied its camera to the new viewport geometry.
            with QtCore.QSignalBlocker(self):
                super().resizeEvent(event)
            self.viewportResized.emit(self)
            self.sigStateChanged.emit(self)
            self.sigResized.emit(self)
            self.sigRangeChanged.emit(self, self.viewRange(), [True, True])
        finally:
            self.resizing = False


def camera(view):
    """Return source center X/Y and source units per logical viewport pixel."""
    rect = view.viewRect()
    return rect.center().x(), rect.center().y(), rect.width() / max(view.width(), 1)


class NavigationGroup:
    """Bidirectional, guarded center/scale synchronization for compatible panes."""

    def __init__(self, views):
        self.views = list(views)
        self.camera = camera(self.views[0])
        self.fitting = False
        self._applying = False
        for view in self.views:
            view.sigRangeChanged.connect(self._changed)
            view.viewportResized.connect(self._resized)

    def dispose(self):
        for view in self.views:
            view.sigRangeChanged.disconnect(self._changed)
            view.viewportResized.disconnect(self._resized)
        self.views.clear()

    def _changed(self, source, *_):
        if self._applying or source.resizing:
            return
        self.fitting = False
        self.camera = camera(source)
        self._apply(exclude=source)

    def _resized(self, _source):
        if self._applying:
            return
        if self.fitting:
            self.fit()
        else:
            self._apply()

    def restore(self, state):
        self.fitting = False
        self.camera = state
        self._apply()

    def fit(self):
        self.fitting = True
        bounds = self.views[0].childrenBoundingRect()
        scale = max(max(bounds.width() / max(view.width(), 1),
                        bounds.height() / max(view.height(), 1))
                    for view in self.views) * 1.04
        self.camera = bounds.center().x(), bounds.center().y(), max(scale, 1e-6)
        self._apply()

    def _apply(self, exclude=None):
        self._applying = True
        try:
            x, y, scale = self.camera
            for view in self.views:
                if view is exclude:
                    continue
                # A snapshot may be installed before the first layout/show.
                # Keep a non-degenerate range until viewportResized applies
                # the same camera to the real geometry.
                width, height = scale * max(view.width(), 1), scale * max(view.height(), 1)
                view.setRange(rect=QtCore.QRectF(x - width / 2, y - height / 2,
                                               width, height), padding=0)
        finally:
            self._applying = False


class ImageGraphicsWidget(pg.GraphicsLayoutWidget):
    """Route native pinch and full-resolution wheel events before scene conversion."""

    roiDragged = QtCore.Signal(object, object, object, bool)

    def __init__(self, *args, **kwargs):
        self._gesture_view = None
        self.draw_roi = False
        self._roi_drag = None
        super().__init__(*args, **kwargs)

    def _view_at(self, position):
        scene = self.mapToScene(position.toPoint())
        for item in self.ci.items:
            if isinstance(item, ImageViewBox) and item.sceneBoundingRect().contains(scene):
                return item, scene
        return None, scene

    @staticmethod
    def _pan(view, delta):
        # Qt already applies the user's natural-scrolling preference. Do not
        # invert a second time. Mapping handles the image's downward Y axis.
        origin = view.mapSceneToView(QtCore.QPointF())
        moved = view.mapSceneToView(QtCore.QPointF(delta))
        view.translateBy(x=origin.x() - moved.x(), y=origin.y() - moved.y())

    @staticmethod
    def _zoom(view, scene, magnification):
        if not math.isfinite(magnification) or magnification <= 0:
            return
        scale = camera(view)[2]
        target = min(1e9, max(1e-6, scale / magnification))
        view.scaleBy((target / scale, target / scale), center=view.mapSceneToView(scene))

    def viewportEvent(self, event):
        kind = event.type()
        if self.draw_roi and kind == QtCore.QEvent.Type.MouseButtonPress and event.button() == QtCore.Qt.MouseButton.LeftButton:
            view, scene = self._view_at(event.position())
            if view is not None:
                start = view.mapSceneToView(scene)
                self._roi_drag = view, start
                self.roiDragged.emit(view, start, start, False)
                event.accept()
                return True
        if self._roi_drag is not None and kind in (QtCore.QEvent.Type.MouseMove,
                                                   QtCore.QEvent.Type.MouseButtonRelease):
            view, start = self._roi_drag
            end = view.mapSceneToView(self.mapToScene(event.position().toPoint()))
            finished = kind == QtCore.QEvent.Type.MouseButtonRelease
            if finished:
                self._roi_drag = None
            self.roiDragged.emit(view, start, end, finished)
            event.accept()
            return True
        if kind not in (QtCore.QEvent.Type.Wheel, QtCore.QEvent.Type.NativeGesture):
            return super().viewportEvent(event)
        view, scene = self._view_at(event.position())
        if self._gesture_view not in self.ci.items:
            self._gesture_view = None
        if kind == QtCore.QEvent.Type.NativeGesture:
            gesture = event.gestureType()
            if gesture == QtCore.Qt.NativeGestureType.EndNativeGesture:
                handled = self._gesture_view is not None
                self._gesture_view = None
                if handled:
                    event.accept()
                    return True
            elif gesture == QtCore.Qt.NativeGestureType.BeginNativeGesture:
                self._gesture_view = view
            view = self._gesture_view or view
            if view is not None:
                if gesture == QtCore.Qt.NativeGestureType.ZoomNativeGesture:
                    self._zoom(view, scene, 1 + event.value())
                elif gesture == QtCore.Qt.NativeGestureType.PanNativeGesture:
                    self._pan(view, event.delta())
                # Consume interleaved rotation: inspection never rotates data.
                event.accept()
                return True
        elif view is not None:
            if self._gesture_view is None:
                pixels = event.pixelDelta()
                trackpad = (not pixels.isNull()
                    or event.phase() != QtCore.Qt.ScrollPhase.NoScrollPhase
                    or event.pointingDevice().type() == QtGui.QInputDevice.DeviceType.TouchPad)
                if trackpad:
                    delta = (QtCore.QPointF(pixels) if not pixels.isNull()
                             else QtCore.QPointF(event.angleDelta()) / 3)
                    self._pan(view, delta)
                else:
                    steps = max(-20, min(20, event.angleDelta().y() / 120))
                    self._zoom(view, scene, 1.2 ** steps)
            event.accept()
            return True
        return super().viewportEvent(event)
