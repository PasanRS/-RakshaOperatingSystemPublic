import QtQuick
import org.kde.kirigami 2 as Kirigami

Rectangle {
    id: root
    color: "#020702"
    property int stage

    Image {
        anchors.fill: parent
        source: "file:///usr/share/wallpapers/RakshaOS/contents/images/1920x1080.jpg"
        fillMode: Image.PreserveAspectCrop
        opacity: 0.38
    }

    Rectangle {
        anchors.fill: parent
        color: "#020702"
        opacity: 0.36
    }

    Column {
        anchors.centerIn: parent
        spacing: Kirigami.Units.largeSpacing

        Image {
            anchors.horizontalCenter: parent.horizontalCenter
            width: Kirigami.Units.gridUnit * 10
            height: width
            source: "file:///etc/calamares/branding/raksha/logo.png"
            fillMode: Image.PreserveAspectFit
            asynchronous: true
        }

        Text {
            anchors.horizontalCenter: parent.horizontalCenter
            text: "RAKSHA OS"
            color: "#d9ffdf"
            font.pixelSize: Kirigami.Units.gridUnit * 2
            font.bold: true
            font.letterSpacing: 4
        }

        Image {
            anchors.horizontalCenter: parent.horizontalCenter
            width: Kirigami.Units.gridUnit * 2
            height: width
            source: "file:///usr/share/plasma/look-and-feel/org.kde.breeze.desktop/contents/splash/images/busywidget.svgz"
            RotationAnimator on rotation {
                from: 0
                to: 360
                duration: 2000
                loops: Animation.Infinite
                running: true
            }
        }
    }
}
