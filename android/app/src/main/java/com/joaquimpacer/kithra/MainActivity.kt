package com.joaquimpacer.kithra

import android.app.Activity
import android.os.Bundle
import android.view.Gravity
import android.view.ViewGroup
import android.widget.LinearLayout
import android.widget.TextView
import android.graphics.Color
import android.graphics.Typeface

class MainActivity : Activity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)

        val root = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            gravity = Gravity.CENTER
            setBackgroundColor(Color.rgb(5, 10, 15))
            setPadding(48, 48, 48, 48)
            layoutParams = ViewGroup.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT,
                ViewGroup.LayoutParams.MATCH_PARENT
            )
        }

        val mark = TextView(this).apply {
            text = "K"
            textSize = 72f
            setTextColor(Color.WHITE)
            gravity = Gravity.CENTER
            typeface = Typeface.DEFAULT_BOLD
        }

        val title = TextView(this).apply {
            text = getString(R.string.app_name)
            textSize = 32f
            setTextColor(Color.WHITE)
            gravity = Gravity.CENTER
            typeface = Typeface.DEFAULT_BOLD
        }

        val status = TextView(this).apply {
            text = getString(R.string.android_beta_status)
            textSize = 16f
            setTextColor(Color.rgb(165, 180, 200))
            gravity = Gravity.CENTER
            setPadding(0, 16, 0, 0)
        }

        root.addView(mark)
        root.addView(title)
        root.addView(status)
        setContentView(root)
    }
}
