import QtQuick
import qs.Commons
import qs.Ui

// The mark, drawn rather than rasterised from an SVG: the bar slot is about
// 16px and Qt's SVG renderer smears strokes at that size.
//
// An O in the mouth of an envelope — Omarchy's letter, not a maker's initial.
// The O is what separates this from every other envelope in the bar, so it is
// the one shape allowed to take up room; the flap is two short strokes off the
// top corners, enough to say "envelope" without closing the O's counter.
// Monochrome here: the bar paints its own foreground, and a brand colour in a
// row of themed glyphs reads as a rendering fault rather than as identity.
Item {
  id: root

  property real iconSize: Style.font.icon
  property color color: Color.foreground
  property color badgeColor: Color.urgent
  // A dot, not a count: the bar says "something arrived", the tooltip says
  // how much, and the window says what.
  property bool dot: false
  property bool crossed: false

  width: iconSize
  height: iconSize
  implicitWidth: iconSize
  implicitHeight: iconSize

  onColorChanged: envelope.requestPaint()
  onIconSizeChanged: envelope.requestPaint()

  Canvas {
    id: envelope
    anchors.fill: parent
    antialiasing: true

    onPaint: {
      var ctx = getContext("2d")
      ctx.reset()
      var w = width
      var h = height
      if (w <= 0 || h <= 0) return

      // The body is inset vertically so a wide-but-short envelope keeps the
      // 3:2 proportion a letter actually has.
      var left = w * 0.06
      var right = w * 0.94
      var top = h * 0.20
      var bottom = h * 0.80
      var stroke = Math.max(1, w * 0.085)

      var innerW = right - left
      var innerH = bottom - top

      ctx.strokeStyle = root.color
      ctx.lineWidth = stroke
      ctx.lineJoin = "round"
      ctx.lineCap = "round"

      // Rounded corners rather than square: the shell's own surfaces are
      // rounded, and at 16px a hard corner is the one pixel that reads as a
      // rendering seam.
      var corner = innerH * 0.18
      ctx.beginPath()
      ctx.moveTo(left + corner, top)
      ctx.lineTo(right - corner, top)
      ctx.quadraticCurveTo(right, top, right, top + corner)
      ctx.lineTo(right, bottom - corner)
      ctx.quadraticCurveTo(right, bottom, right - corner, bottom)
      ctx.lineTo(left + corner, bottom)
      ctx.quadraticCurveTo(left, bottom, left, bottom - corner)
      ctx.lineTo(left, top + corner)
      ctx.quadraticCurveTo(left, top, left + corner, top)
      ctx.closePath()
      ctx.stroke()

      // The O, centred in the body at the frame's own weight. A lighter or
      // smaller ring loses its counter at bar size and fills in to a dot, which
      // is the one thing it must not look like — the unread badge is a dot.
      // 0.34 of the body height is the largest radius that still leaves clear
      // air between the ring and the frame on a 16px square.
      ctx.beginPath()
      ctx.arc(left + innerW * 0.5, top + innerH * 0.5, innerH * 0.34, 0, Math.PI * 2)
      ctx.stroke()

      // The flap, as two short strokes falling from the top corners. Drawn
      // lighter and stopped well short of the centre: carried any further they
      // meet the top of the O and the pair reads as a horned head rather than
      // as a letter, and at bar size a full-weight flap just thickens the top
      // edge into a bar.
      ctx.lineWidth = Math.max(1, stroke * 0.7)
      ctx.beginPath()
      ctx.moveTo(left, top)
      ctx.lineTo(left + innerW * 0.16, top + innerH * 0.20)
      ctx.moveTo(right, top)
      ctx.lineTo(right - innerW * 0.16, top + innerH * 0.20)
      ctx.stroke()
    }
  }

  Rectangle {
    visible: root.crossed
    anchors.centerIn: parent
    width: parent.width * 1.22
    height: Math.max(2, parent.height * 0.13)
    radius: height / 2
    color: root.color
    rotation: -45
  }

  // On the corner rather than beside the icon, so the bar slot stays one
  // square whether or not anything is waiting.
  BorderSurface {
    visible: root.dot
    width: Math.max(Style.space(5), parent.width * 0.34)
    height: width
    radius: width / 2
    color: root.badgeColor
    anchors.right: parent.right
    anchors.rightMargin: -parent.width * 0.06
    anchors.top: parent.top
    anchors.topMargin: -parent.height * 0.04
    borderSpec: Border.flat(Color.popups.background, 1)
  }
}
