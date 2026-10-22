import Foundation

/// Manual button workflow for the hardware-tested 1500W family.
/// Advancing a guide step sends no command and does not assert a physical result.
public enum CartridgeGuide {
    public static let titles = ["Prepare the printer", "Prepare the cartridge", "Move to replacement position", "Replace the cartridge", "Finish ink charging"]
    public static let instructions = [
        "Remove the CD/DVD tray. Wait until the printer's power light is steady and printing has stopped.",
        "Have the new cartridge ready. Remove its yellow tape; keep the other seals intact and avoid touching the green chip.",
        "Open the printer cover. Briefly press the ink button and wait for the carriage to stop. Do not hold it for more than three seconds or move the carriage by hand.",
        "Open the cartridge cover. Release and lift out the old cartridge, then promptly insert the replacement until it clicks. Close both covers.",
        "Press the ink button again. Leave the printer on while ink charges, usually about two minutes. Wait until the power light is steady before printing or inserting the CD/DVD tray."
    ]
}
