import Foundation

public enum OnboardingStep: Int, CaseIterable, Sendable {
    case welcome
    case detectOllama
    case pickModels
    case pullModels
    case done
}
