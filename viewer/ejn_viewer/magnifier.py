"""Bounded nearest-sample patches for linked local pixel inspection."""

import html

import pyqtgraph as pg
from PySide6 import QtCore, QtWidgets


PATCH_SIZE = 31
MAX_PATCH_BYTES = 4 * PATCH_SIZE * PATCH_SIZE * 16


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

    def display(self, planes, row, col):
        """PLANES contains at most four (key, label, source, levels) tuples."""
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
        for name, label, array, levels in planes:
            self.labels[name].setText(html.escape(label[:48]))
            top, left = max(0, row - PATCH_SIZE // 2), max(0, col - PATCH_SIZE // 2)
            bottom = min(array.shape[0], top + PATCH_SIZE)
            right = min(array.shape[1], left + PATCH_SIZE)
            # Copy only this tiny patch: retaining a slice view here would keep
            # its entire old publication alive after candidate replacement.
            patch = array[top:bottom, left:right].copy(order="C")
            self.items[name].setImage(patch, autoLevels=False, levels=levels)
            view, cross = self.views[name]
            cross.setData(x=[col - left + .5], y=[row - top + .5])
            view.setRange(rect=QtCore.QRectF(0, 0, max(1, patch.shape[1]),
                                           max(1, patch.shape[0])), padding=0)
