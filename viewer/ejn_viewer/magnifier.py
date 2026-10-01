"""Bounded nearest-sample patches for linked local pixel inspection."""

import html
import math

import pyqtgraph as pg
from PySide6 import QtCore, QtWidgets
from .spatial import plane_geometry


PATCH_SIZE = 31
MAX_PATCH_BYTES = 6 * PATCH_SIZE * PATCH_SIZE * 16


class Magnifier(QtWidgets.QWidget):
    def __init__(self, parent=None):
        super().__init__(parent)
        layout = QtWidgets.QVBoxLayout(self)
        layout.setContentsMargins(0, 0, 0, 0)
        self.graphics = pg.GraphicsLayoutWidget(self)
        self.graphics.setFixedHeight(125)
        layout.addWidget(self.graphics)
        self.items = {}
        self.views = {}
        self.labels = {}
        self.names = ()

    def clear(self):
        for item in self.items.values():
            item.clear()
            item.deleteLater()
        self.items.clear()
        self.views.clear()
        self.labels.clear()
        self.graphics.clear()
        self.names = ()

    def display(self, planes, row, col, *, metadata=None, world=None):
        """PLANES contains at most six (key, label, source, levels) tuples."""
        metadata = metadata or {}
        names = tuple(entry[0] for entry in planes)
        if names != self.names:
            self.clear()
            self.names = names
            for index, (name, label, _array, _levels) in enumerate(planes):
                self.labels[name] = self.graphics.addLabel(html.escape(label[:48]), row=0, col=index)
                view = pg.ViewBox(lockAspect=True, enableMenu=False)
                view.setMouseEnabled(x=False, y=False)
                view.invertY(True)
                self.graphics.addItem(view, row=1, col=index)
                item = pg.ImageItem(axisOrder="row-major")
                item.setAutoDownsample(False)
                view.addItem(item)
                cross = pg.ScatterPlotItem(size=7, pen=pg.mkPen("y"), brush=None, symbol="+")
                view.addItem(cross, ignoreBounds=True)
                self.items[name] = item
                self.views[name] = view, cross
        if world is not None and planes:
            # Share one physical field of view, bounded by the finest grid.
            # Two spare edge samples keep every copied patch <= PATCH_SIZE².
            geometries = {name: plane_geometry(metadata.get(name, {})) for name, *_ in planes}
            width = min(geometry.spacing[1] for geometry in geometries.values()) * (PATCH_SIZE - 2)
            height = min(geometry.spacing[0] for geometry in geometries.values()) * (PATCH_SIZE - 2)
            rect = QtCore.QRectF(world[0] - width / 2, world[1] - height / 2, width, height)
        else:
            geometries = None
        for name, label, array, levels in planes:
            self.labels[name].setText(html.escape(label[:48]))
            if geometries is not None:
                geometry = geometries[name]
                x0, y0 = geometry.world_to_pixel(rect.left(), rect.top())
                x1, y1 = geometry.world_to_pixel(rect.right(), rect.bottom())
                top, left = max(0, min(array.shape[0], math.floor(y0))), max(0, min(array.shape[1], math.floor(x0)))
                bottom = max(top, min(array.shape[0], math.ceil(y1), top + PATCH_SIZE))
                right = max(left, min(array.shape[1], math.ceil(x1), left + PATCH_SIZE))
            else:
                top, left = max(0, row - PATCH_SIZE // 2), max(0, col - PATCH_SIZE // 2)
                bottom = min(array.shape[0], top + PATCH_SIZE)
                right = min(array.shape[1], left + PATCH_SIZE)
            # Copy only this tiny patch: retaining a slice view here would keep
            # its entire old publication alive after candidate replacement.
            patch = array[top:bottom, left:right].copy(order="C")
            if patch.size:
                self.items[name].setImage(patch, autoLevels=False, levels=levels)
            else:
                self.items[name].clear()
            view, cross = self.views[name]
            if geometries is not None:
                x, y = geometry.pixel_to_world(left, top)
                if patch.size:
                    self.items[name].setRect(QtCore.QRectF(x, y, patch.shape[1] * geometry.spacing[1],
                                                          patch.shape[0] * geometry.spacing[0]))
                cross.setData(x=[world[0]], y=[world[1]])
                view.setRange(rect=rect, padding=0)
            else:
                self.items[name].resetTransform()
                self.items[name].setPos(0, 0)
                cross.setData(x=[col - left + .5], y=[row - top + .5])
                view.setRange(rect=QtCore.QRectF(0, 0, max(1, patch.shape[1]),
                                               max(1, patch.shape[0])), padding=0)
