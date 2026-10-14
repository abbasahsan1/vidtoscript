import SwiftUI

struct AnimatedSplashScreen: View {
    @State private var isPulsing = false
    @State private var showLines = false
    private let waveHeights: [CGFloat] = [18, 28, 14, 24, 20]
    
    var body: some View {
        ZStack {
            // Background Canvas
            Color.black.ignoresSafeArea()
            
            // Rounded squircle card with linear gradient
            RoundedRectangle(cornerRadius: 38, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [Color(hex: "#4F46E5"), Color(hex: "#7C3AED"), Color(hex: "#C026D3")],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .frame(width: 220, height: 220)
                .shadow(color: Color(hex: "#7C3AED").opacity(0.3), radius: 20, x: 0, y: 10)
            
            // Vector Graphic Overlay
            ZStack {
                // Document Base
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(Color.white.opacity(0.12))
                    .frame(width: 140, height: 160)
                
                // Play Button
                ZStack {
                    Circle()
                        .fill(
                            LinearGradient(
                                colors: [Color(hex: "#38BDF8"), Color(hex: "#818CF8")],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                        .frame(width: 50, height: 50)
                        .scaleEffect(isPulsing ? 1.08 : 1.0)
                        .shadow(color: Color(hex: "#38BDF8").opacity(0.5), radius: isPulsing ? 15 : 5)
                        
                    Image(systemName: "play.fill")
                        .font(.system(size: 20))
                        .foregroundColor(.white)
                }
                .offset(y: -30)
                
                // Soundwaves
                HStack(spacing: 6) {
                    ForEach(0..<5) { index in
                        Capsule()
                            .fill(index % 2 == 0 ? Color(hex: "#38BDF8") : Color(hex: "#F43F5E"))
                            .frame(width: 4, height: isPulsing ? waveHeights[index] : 10)
                            .opacity(isPulsing ? 1.0 : 0.5)
                            .animation(.easeInOut(duration: 0.5).repeatForever().delay(Double(index) * 0.1), value: isPulsing)
                    }
                }
                .offset(y: 10)
                
                // Transcribed Text Lines
                VStack(alignment: .leading, spacing: 6) {
                    RoundedRectangle(cornerRadius: 4)
                        .fill(Color.white.opacity(0.8))
                        .frame(width: showLines ? 100 : 0, height: 6)
                        .animation(.timingCurve(0.4, 0, 0.2, 1).delay(0.2), value: showLines)
                    
                    RoundedRectangle(cornerRadius: 4)
                        .fill(Color.white.opacity(0.8))
                        .frame(width: showLines ? 80 : 0, height: 6)
                        .animation(.timingCurve(0.4, 0, 0.2, 1).delay(0.4), value: showLines)
                    
                    RoundedRectangle(cornerRadius: 4)
                        .fill(Color.white.opacity(0.8))
                        .frame(width: showLines ? 60 : 0, height: 6)
                        .animation(.timingCurve(0.4, 0, 0.2, 1).delay(0.6), value: showLines)
                }
                .frame(width: 100, alignment: .leading)
                .offset(y: 45)
            }
        }
        .onAppear {
            withAnimation(.easeInOut(duration: 1.0).repeatForever()) {
                isPulsing = true
            }
            showLines = true
        }
    }
}

// Extension to initialize Color from hex string
extension Color {
    init(hex: String) {
        let hex = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var int: UInt64 = 0
        Scanner(string: hex).scanHexInt64(&int)
        let a, r, g, b: UInt64
        switch hex.count {
        case 3: // RGB (12-bit)
            (a, r, g, b) = (255, (int >> 8) * 17, (int >> 4 & 0xF) * 17, (int & 0xF) * 17)
        case 6: // RGB (24-bit)
            (a, r, g, b) = (255, int >> 16, int >> 8 & 0xFF, int & 0xFF)
        case 8: // ARGB (32-bit)
            (a, r, g, b) = (int >> 24, int >> 16 & 0xFF, int >> 8 & 0xFF, int & 0xFF)
        default:
            (a, r, g, b) = (255, 0, 0, 0)
        }

        self.init(
            .sRGB,
            red: Double(r) / 255,
            green: Double(g) / 255,
            blue:  Double(b) / 255,
            opacity: Double(a) / 255
        )
    }
}
