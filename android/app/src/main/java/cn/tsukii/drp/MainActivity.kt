package cn.tsukii.drp

import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.compose.foundation.isSystemInDarkTheme
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.darkColorScheme
import androidx.compose.material3.lightColorScheme
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.runtime.Composable
import androidx.compose.ui.graphics.Color

class MainActivity : ComponentActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        enableEdgeToEdge()
        setContent { DRPTheme { DRPApp() } }
    }
}

@Composable
fun DRPTheme(content: @Composable () -> Unit) {
    val colors = if (isSystemInDarkTheme()) darkColorScheme(
        primary = Color(0xFFAFC6FF), onPrimary = Color(0xFF002D70), primaryContainer = Color(0xFF17468F),
        onPrimaryContainer = Color(0xFFD9E2FF), secondary = Color(0xFFBEC6DC),
        background = Color(0xFF111318), surface = Color(0xFF111318), surfaceContainer = Color(0xFF1D2028)
    ) else lightColorScheme(
        primary = Color(0xFF4176E6), onPrimary = Color.White, primaryContainer = Color(0xFFE4ECFF),
        onPrimaryContainer = Color(0xFF163E83), secondary = Color(0xFF53617D),
        background = Color(0xFFFAFBFF), surface = Color(0xFFFAFBFF), surfaceContainer = Color(0xFFF0F3FA)
    )
    MaterialTheme(colorScheme = colors, content = content)
}
