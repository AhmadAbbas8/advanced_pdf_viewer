package com.example.advanced_pdf_viewer

import android.content.Context
import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.Paint
import android.graphics.Path
import android.graphics.PointF
import android.graphics.RectF
import android.graphics.drawable.GradientDrawable
import android.graphics.pdf.PdfRenderer
import android.os.Build
import android.os.ParcelFileDescriptor
import android.os.Handler
import android.os.Looper
import android.os.VibrationEffect
import android.os.Vibrator
import android.os.VibratorManager
import android.view.MotionEvent
import android.view.GestureDetector
import android.view.ScaleGestureDetector
import android.view.View
import android.view.ViewGroup
import android.view.Gravity
import android.view.animation.DecelerateInterpolator
import android.animation.ValueAnimator
import android.widget.FrameLayout
import android.widget.LinearLayout
import android.widget.ImageView
import android.widget.TextView
import androidx.recyclerview.widget.LinearLayoutManager
import androidx.recyclerview.widget.RecyclerView
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.platform.PlatformView
import java.io.File
import java.util.Stack
import java.text.Bidi
import java.util.concurrent.Executors

import com.tom_roush.pdfbox.pdmodel.PDDocument
import com.tom_roush.pdfbox.pdmodel.PDPageContentStream
import com.tom_roush.pdfbox.android.PDFBoxResourceLoader
import com.tom_roush.pdfbox.pdmodel.font.PDType0Font
import com.tom_roush.pdfbox.pdmodel.font.PDFont
import com.tom_roush.pdfbox.pdmodel.graphics.state.PDExtendedGraphicsState
import com.tom_roush.pdfbox.pdmodel.graphics.blend.BlendMode
import com.tom_roush.pdfbox.io.MemoryUsageSetting
import com.tom_roush.pdfbox.text.PDFTextStripper
import com.tom_roush.pdfbox.text.TextPosition

class AndroidPdfView(
    private val context: Context,
    private val id: Int,
    private val creationParams: Map<String, Any>?,
    private val messenger: BinaryMessenger
) : PlatformView, MethodChannel.MethodCallHandler {

    // ─────────────────────────────────────────────────────────────────────────
    // Scrollable layout manager
    // ─────────────────────────────────────────────────────────────────────────

    private class LockableLinearLayoutManager(context: Context) : LinearLayoutManager(context) {
        var scrollable = true
        override fun canScrollVertically(): Boolean = scrollable && super.canScrollVertically()
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Handle View — mimics iOS circular drag handle
    // ─────────────────────────────────────────────────────────────────────────

    inner class SelectionHandleView(context: Context, val isStart: Boolean) : View(context) {
        // Position in the AnnotationImageView's coordinate space (view-space, not PDF-space)
        var anchorX: Float = 0f
        var anchorY: Float = 0f

        private val circlePaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
            style = Paint.Style.FILL
        }
        private val stemPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
            style = Paint.Style.FILL
        }
        private val shadowPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
            style = Paint.Style.FILL
            color = Color.argb(40, 0, 0, 0)
        }

        private val R = 22f   // circle radius dp→px done at draw time
        private val STEM_W = 4f
        private val STEM_H = 20f
        private val SIZE = ((R * 2 + STEM_H + 8f) * resources.displayMetrics.density).toInt()

        init {
            layoutParams = FrameLayout.LayoutParams(SIZE, SIZE)
            elevation = 8f
        }

        fun setColor(color: Int) {
            val solidColor = Color.argb(255, Color.red(color), Color.green(color), Color.blue(color))
            circlePaint.color = solidColor
            stemPaint.color   = solidColor
            invalidate()
        }

        override fun onDraw(canvas: Canvas) {
            val density = resources.displayMetrics.density
            val r    = R * density
            val stemW = STEM_W * density
            val stemH = STEM_H * density

            // Shadow
            canvas.drawCircle(width / 2f, stemH + r + density * 2, r + density * 2, shadowPaint)

            // Stem + circle
            val cx = width / 2f
            canvas.drawRoundRect(
                cx - stemW / 2, if (isStart) 0f else stemH,
                cx + stemW / 2, if (isStart) stemH else stemH + stemH,
                stemW / 2, stemW / 2, stemPaint
            )
            canvas.drawCircle(cx, if (isStart) stemH + r else r, r, circlePaint)
        }

        /** Animate the handle springing into view */
        fun animateAppear() {
            scaleX = 0.1f; scaleY = 0.1f; alpha = 0f
            animate().scaleX(1f).scaleY(1f).alpha(1f)
                .setDuration(200).setInterpolator(DecelerateInterpolator(1.5f)).start()
        }

        /** Animate the handle out, then remove */
        fun animateDisappear(onDone: (() -> Unit)? = null) {
            animate().scaleX(0.1f).scaleY(0.1f).alpha(0f)
                .setDuration(120).setInterpolator(DecelerateInterpolator())
                .withEndAction { (parent as? ViewGroup)?.removeView(this); onDone?.invoke() }
                .start()
        }
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Core fields
    // ─────────────────────────────────────────────────────────────────────────

    private val recyclerView = RecyclerView(context)
    private val layoutManager = LockableLinearLayoutManager(context)
    private val methodChannel: MethodChannel = MethodChannel(messenger, "advanced_pdf_viewer_$id")

    private val pdfRendererLock = Any()
    private val pdfBoxLock      = Any()
    private var pdfRenderer: PdfRenderer? = null
    private var parcelFileDescriptor: ParcelFileDescriptor? = null
    private var interactionDocument: PDDocument? = null

    private var currentPath: String? = null
    private var currentTool: String = "none"
    private var isTempFile: Boolean = false

    private val renderExecutor      = Executors.newFixedThreadPool(2)
    private val interactionExecutor = Executors.newSingleThreadExecutor()
    private val mainHandler         = Handler(Looper.getMainLooper())

    private var drawColor:       Int     = Color.RED
    private var highlightColor:  Int     = Color.YELLOW
    private var underlineColor:  Int     = Color.BLUE
    private var enablePageNumber: Boolean = false
    private var currentPage:     Int     = 0

    // Search
    private var searchResults      = mutableListOf<SearchMatch>()
    private var currentSearchIndex = -1
    private val searchAllColor     = Color.argb(115, 255, 255, 0)
    private val searchCurrentColor = Color.argb(178, 255, 128, 0)

    private val undoStack = Stack<Annotation>()
    private val redoStack = Stack<Annotation>()

    private var currentScale: Float = 1.0f
    private var translateX:   Float = 0f
    private var translateY:   Float = 0f
    private val minScale:     Float = 1.0f
    private val maxScale:     Float = 5.0f

    // ─────────────────────────────────────────────────────────────────────────
    // Zoom gesture detectors
    // ─────────────────────────────────────────────────────────────────────────

    private val scaleDetector = ScaleGestureDetector(context, object : ScaleGestureDetector.SimpleOnScaleGestureListener() {
        override fun onScale(detector: ScaleGestureDetector): Boolean {
            val prev = currentScale
            currentScale = (currentScale * detector.scaleFactor).coerceIn(minScale, maxScale)
            val fx = detector.focusX; val fy = detector.focusY
            translateX -= (fx / prev - fx / currentScale) * currentScale
            translateY -= (fy / prev - fy / currentScale) * currentScale
            updateZoom(); return true
        }
    })

    private val panGestureDetector = GestureDetector(context, object : GestureDetector.SimpleOnGestureListener() {
        override fun onScroll(e1: MotionEvent?, e2: MotionEvent, dX: Float, dY: Float): Boolean {
            if (currentScale > 1.0f && currentTool == "none") {
                translateX -= dX; translateY -= dY; updateZoom(); return true
            }
            return false
        }
    })

    private val bitmapCache = object : android.util.LruCache<Int, Bitmap>((Runtime.getRuntime().maxMemory() / 8).toInt()) {
        override fun sizeOf(key: Int, value: Bitmap): Int = value.byteCount
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Init
    // ─────────────────────────────────────────────────────────────────────────

    init {
        try { PDFBoxResourceLoader.init(context) } catch (e: Throwable) {
            System.err.println("PDF View Critical Error initializing PDFBox: ${e.message}")
        }

        recyclerView.layoutManager = layoutManager
        recyclerView.adapter       = PdfAdapter()
        recyclerView.setItemViewCacheSize(3)
        recyclerView.setHasFixedSize(true)

        recyclerView.addOnScrollListener(object : RecyclerView.OnScrollListener() {
            override fun onScrolled(rv: RecyclerView, dx: Int, dy: Int) {
                val pos = layoutManager.findFirstVisibleItemPosition()
                if (pos >= 0 && pos != currentPage) {
                    currentPage = pos
                    mainHandler.post { methodChannel.invokeMethod("onPageChanged", currentPage) }
                }
            }
        })

        recyclerView.setOnTouchListener { _, event ->
            scaleDetector.onTouchEvent(event)
            if (scaleDetector.isInProgress) return@setOnTouchListener true
            if (currentScale > 1.0f) { panGestureDetector.onTouchEvent(event); return@setOnTouchListener true }
            false
        }

        methodChannel.setMethodCallHandler(this)
        isTempFile = creationParams?.get("isTempFile") as? Boolean ?: false
        val path = creationParams?.get("path") as? String
        if (path != null) loadPdf(path)
    }

    override fun getView(): View = recyclerView

    override fun dispose() {
        pdfRenderer?.close(); parcelFileDescriptor?.close()
        interactionExecutor.execute {
            try { interactionDocument?.close(); interactionDocument = null } catch (_: Exception) {}
        }
        interactionExecutor.shutdown(); bitmapCache.evictAll(); renderExecutor.shutdown()
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Load PDF
    // ─────────────────────────────────────────────────────────────────────────

    private fun loadPdf(path: String) {
        currentPath = path
        val file = File(path)
        if (!file.exists() || file.length() == 0L) {
            System.err.println("PDF View Error: File does not exist or is empty: $path"); return
        }
        try {
            parcelFileDescriptor = ParcelFileDescriptor.open(file, ParcelFileDescriptor.MODE_READ_ONLY)
            pdfRenderer = PdfRenderer(parcelFileDescriptor!!)
            recyclerView.adapter?.notifyDataSetChanged()
            interactionExecutor.execute {
                try {
                    synchronized(pdfBoxLock) {
                        interactionDocument?.close()
                        interactionDocument = PDDocument.load(file, MemoryUsageSetting.setupTempFileOnly())
                    }
                } catch (e: Exception) { e.printStackTrace() }
            }
        } catch (e: Throwable) {
            System.err.println("PDF View Critical Error initializing PdfRenderer: ${e.message}")
        }
    }

    // ─────────────────────────────────────────────────────────────────────────
    // RecyclerView Adapter
    // ─────────────────────────────────────────────────────────────────────────

    inner class PdfAdapter : RecyclerView.Adapter<PdfViewHolder>() {
        override fun onCreateViewHolder(parent: ViewGroup, viewType: Int): PdfViewHolder {
            val container = LinearLayout(context).apply {
                orientation = LinearLayout.VERTICAL
                layoutParams = RecyclerView.LayoutParams(RecyclerView.LayoutParams.MATCH_PARENT, RecyclerView.LayoutParams.WRAP_CONTENT)
                gravity = Gravity.CENTER_HORIZONTAL
            }
            val pdfView = AnnotationImageView(context, 0, 1, 1).apply {
                layoutParams = LinearLayout.LayoutParams(LinearLayout.LayoutParams.MATCH_PARENT, LinearLayout.LayoutParams.WRAP_CONTENT)
                adjustViewBounds = true
            }
            val pageNumView = TextView(context).apply {
                layoutParams = LinearLayout.LayoutParams(LinearLayout.LayoutParams.WRAP_CONTENT, LinearLayout.LayoutParams.WRAP_CONTENT)
                gravity = Gravity.CENTER; setTextColor(Color.BLACK); textSize = 12f; setPadding(0, 8, 0, 16)
            }
            container.addView(pdfView); container.addView(pageNumView)
            return PdfViewHolder(container)
        }

        override fun onBindViewHolder(holder: PdfViewHolder, position: Int) {
            val renderer = pdfRenderer ?: return
            if (position < 0 || position >= renderer.pageCount) return
            val container   = holder.itemView as LinearLayout
            val imageView   = container.getChildAt(0) as AnnotationImageView
            val pageNumView = container.getChildAt(1) as TextView
            pageNumView.text = "${position + 1}"
            pageNumView.visibility = if (enablePageNumber) View.VISIBLE else View.GONE

            var w = 0; var h = 0
            try { synchronized(pdfRendererLock) { val p = renderer.openPage(position); w = p.width; h = p.height; p.close() } } catch (_: Exception) { return }
            imageView.updatePageInfo(position, w, h)

            val cached = bitmapCache.get(position)
            if (cached != null) { imageView.setImageBitmap(cached) } else {
                imageView.setImageBitmap(null)
                renderExecutor.execute {
                    try {
                        synchronized(pdfRendererLock) {
                            val page = pdfRenderer?.openPage(position) ?: return@execute
                            var bitmap: Bitmap? = null
                            try {
                                val scale = 1.5f
                                bitmap = Bitmap.createBitmap((w * scale).toInt(), (h * scale).toInt(), Bitmap.Config.ARGB_8888)
                                page.render(bitmap, null, null, PdfRenderer.Page.RENDER_MODE_FOR_DISPLAY)
                            } catch (_: OutOfMemoryError) {
                                try { bitmap = Bitmap.createBitmap(w, h, Bitmap.Config.ARGB_8888); page.render(bitmap, null, null, PdfRenderer.Page.RENDER_MODE_FOR_DISPLAY) } catch (_: OutOfMemoryError) {}
                            }
                            page.close()
                            bitmap?.let { bmp ->
                                bitmapCache.put(position, bmp)
                                mainHandler.post { if (imageView.pageIndex == position) imageView.setImageBitmap(bmp) }
                            }
                        }
                    } catch (e: Exception) { e.printStackTrace() }
                }
            }
        }
        override fun getItemCount(): Int = pdfRenderer?.pageCount ?: 0
    }

    class PdfViewHolder(view: View) : RecyclerView.ViewHolder(view)

    // ─────────────────────────────────────────────────────────────────────────
    // Method Channel
    // ─────────────────────────────────────────────────────────────────────────

    private fun getIntArg(call: MethodCall, key: String): Int?    = (call.argument<Any>(key) as? Number)?.toInt()
    private fun getDoubleArg(call: MethodCall, key: String): Double? = (call.argument<Any>(key) as? Number)?.toDouble()

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "setDrawingMode" -> {
                currentTool = call.argument<String>("tool") ?: "none"
                layoutManager.scrollable = currentTool == "none"
                result.success(null)
            }
            "setScrollLocked" -> { layoutManager.scrollable = !(call.argument<Boolean>("locked") ?: false); result.success(null) }
            "clearAnnotations" -> { undoStack.clear(); redoStack.clear(); refreshAllViews(); result.success(null) }
            "undo" -> { if (undoStack.isNotEmpty()) { redoStack.push(undoStack.pop()); refreshAllViews() }; result.success(null) }
            "redo" -> { if (redoStack.isNotEmpty()) { undoStack.push(redoStack.pop()); refreshAllViews() }; result.success(null) }
            "savePdf" -> savePdf(result)
            "addTextAnnotation" -> {
                val text = call.argument<String>("text")
                val origX = getDoubleArg(call, "x")?.toFloat() ?: 0f
                val origY = getDoubleArg(call, "y")?.toFloat() ?: 0f
                val pageIndex = getIntArg(call, "pageIndex") ?: 0
                val color = getIntArg(call, "color") ?: Color.BLACK
                val fontSize = getDoubleArg(call, "fontSize")?.toFloat() ?: 14f
                val deltaX = getDoubleArg(call, "deltaX")?.toFloat() ?: 0f
                val deltaY = getDoubleArg(call, "deltaY")?.toFloat() ?: 0f

                val finalLogicalX = origX + deltaX
                val finalLogicalY = origY + deltaY
                val density = recyclerView.context.resources.displayMetrics.density
                val physX = finalLogicalX * density
                val physY = finalLogicalY * density

                val unscaledX = (physX - translateX) / currentScale
                val unscaledY = (physY - translateY) / currentScale

                var targetChild: AnnotationImageView? = null
                var targetPageIndex = pageIndex

                // Hit-test which page the text was dropped on
                for (i in 0 until recyclerView.childCount) {
                    val view = recyclerView.getChildAt(i)
                    if (unscaledY >= view.top && unscaledY <= view.bottom) {
                        if (view is ViewGroup && view.childCount > 0) {
                            targetChild = view.getChildAt(0) as? AnnotationImageView
                        }
                        targetPageIndex = recyclerView.getChildAdapterPosition(view)
                        break
                    }
                }

                // If dragged out of bounds, clamp to first or last visible view
                if (targetChild == null && recyclerView.childCount > 0) {
                    if (unscaledY < recyclerView.getChildAt(0).top) {
                        val view = recyclerView.getChildAt(0)
                        if (view is ViewGroup && view.childCount > 0) {
                            targetChild = view.getChildAt(0) as? AnnotationImageView
                        }
                        targetPageIndex = recyclerView.getChildAdapterPosition(view)
                    } else {
                        val view = recyclerView.getChildAt(recyclerView.childCount - 1)
                        if (view is ViewGroup && view.childCount > 0) {
                            targetChild = view.getChildAt(0) as? AnnotationImageView
                        }
                        targetPageIndex = recyclerView.getChildAdapterPosition(view)
                    }
                }

                // Fallback to original pageIndex if still null
                if (targetChild == null) {
                    val view = (recyclerView.layoutManager as LinearLayoutManager).findViewByPosition(pageIndex)
                    if (view is ViewGroup && view.childCount > 0) {
                        targetChild = view.getChildAt(0) as? AnnotationImageView
                    }
                }

                if (targetChild != null) {
                    // Adjust unscaled coordinates by the container's top offset AND the image view's top offset
                    // targetChild.parent gives the LinearLayout container.
                    val parentView = targetChild.parent as? View
                    val parentTop = parentView?.top ?: 0
                    val parentLeft = parentView?.left ?: 0
                    
                    val localX = unscaledX - parentLeft - targetChild.left
                    val localY = unscaledY - parentTop - targetChild.top
                    val scale = if (targetChild.width == 0) 1f else targetChild.pdfWidth / targetChild.width.toFloat()
                    val pdfX = localX * scale
                    val pdfY = localY * scale

                    if (text != null) {
                        addAnnotation(Annotation(targetPageIndex, "text", pdfX, pdfY, 200f, 50f, text, color, fontSize = fontSize))
                        result.success(null)
                    } else {
                        result.error("INVALID_ARGUMENTS", "Text is required", null)
                    }
                } else {
                    result.error("VIEW_NOT_FOUND", "Page view not found", null)
                }
            }
            "jumpToPage" -> { (layoutManager as? LinearLayoutManager)?.scrollToPositionWithOffset(getIntArg(call, "page") ?: 0, 0); result.success(null) }
            "getTotalPages" -> result.success(pdfRenderer?.pageCount ?: 0)
            "updateConfig" -> {
                getIntArg(call, "drawColor")?.let      { drawColor      = it }
                getIntArg(call, "highlightColor")?.let { highlightColor = it }
                getIntArg(call, "underlineColor")?.let { underlineColor = it }
                call.argument<Boolean>("enablePageNumber")?.let { enablePageNumber = it; refreshAllViews() }
                result.success(null)
            }
            "zoomIn"  -> { currentScale = (currentScale + 0.5f).coerceAtMost(maxScale); updateZoom(); result.success(null) }
            "zoomOut" -> { currentScale = (currentScale - 0.5f).coerceAtLeast(minScale); if (currentScale == 1f) { translateX = 0f; translateY = 0f }; updateZoom(); result.success(null) }
            "setZoom" -> {
                currentScale = (getDoubleArg(call, "scale")?.toFloat() ?: 1f).coerceIn(minScale, maxScale)
                if (currentScale == 1f) { translateX = 0f; translateY = 0f }; updateZoom(); result.success(null)
            }
            "getCurrentPage"     -> result.success(currentPage)
            "searchText"         -> { searchText(call.argument<String>("query") ?: ""); result.success(null) }
            "nextSearchResult"   -> { nextSearchResult(); result.success(null) }
            "previousSearchResult" -> { previousSearchResult(); result.success(null) }
            "clearSearch"        -> { clearSearch(); result.success(null) }
            else -> result.notImplemented()
        }
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Zoom
    // ─────────────────────────────────────────────────────────────────────────

    private fun updateZoom() {
        if (currentScale > 1f) {
            translateX = translateX.coerceIn(-(recyclerView.width  * currentScale - recyclerView.width),  0f)
            translateY = translateY.coerceIn(-(recyclerView.height * currentScale - recyclerView.height), 0f)
        } else { translateX = 0f; translateY = 0f }
        recyclerView.scaleX = currentScale; recyclerView.scaleY = currentScale
        recyclerView.translationX = translateX; recyclerView.translationY = translateY
        recyclerView.pivotX = 0f; recyclerView.pivotY = 0f
    }

    private fun addAnnotation(anno: Annotation) { undoStack.push(anno); redoStack.clear(); refreshAllViews() }
    private fun refreshAllViews() { recyclerView.adapter?.notifyDataSetChanged() }

    // ─────────────────────────────────────────────────────────────────────────
    // Haptic Feedback
    // ─────────────────────────────────────────────────────────────────────────

    enum class HapticStyle { LIGHT, MEDIUM, HEAVY }

    private fun triggerHaptic(style: HapticStyle) {
        try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
                val vm = context.getSystemService(Context.VIBRATOR_MANAGER_SERVICE) as? VibratorManager
                val v  = vm?.defaultVibrator ?: return
                val effect = when (style) {
                    HapticStyle.LIGHT  -> VibrationEffect.createPredefined(VibrationEffect.EFFECT_TICK)
                    HapticStyle.MEDIUM -> VibrationEffect.createPredefined(VibrationEffect.EFFECT_CLICK)
                    HapticStyle.HEAVY  -> VibrationEffect.createPredefined(VibrationEffect.EFFECT_HEAVY_CLICK)
                }
                v.vibrate(effect)
            } else {
                @Suppress("DEPRECATION")
                val v = context.getSystemService(Context.VIBRATOR_SERVICE) as? Vibrator ?: return
                val ms = when (style) { HapticStyle.LIGHT -> 20L; HapticStyle.MEDIUM -> 40L; HapticStyle.HEAVY -> 60L }
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                    v.vibrate(VibrationEffect.createOneShot(ms, VibrationEffect.DEFAULT_AMPLITUDE))
                } else {
                    @Suppress("DEPRECATION") v.vibrate(ms)
                }
            }
        } catch (_: Exception) {}
    }

    // ─────────────────────────────────────────────────────────────────────────
    // AnnotationImageView — enhanced with handles, preview, word-snapping,
    //                       double-tap sentence select, RTL awareness
    // ─────────────────────────────────────────────────────────────────────────

    data class WordBounds(val rect: RectF, val text: String, val startPos: Int, val endPos: Int)

    inner class AnnotationImageView(
        context: Context,
        var pageIndex: Int,
        var pdfWidth: Int,
        var pdfHeight: Int
    ) : ImageView(context) {

        fun updatePageInfo(index: Int, width: Int, height: Int) {
            pageIndex = index; pdfWidth = width; pdfHeight = height; invalidate()
        }

        // ── Drawing state ────────────────────────────────────────────────────
        private var currentDrawingPath   = Path()
        private var currentDrawingPoints = mutableListOf<PointF>()

        // ── Live selection state ─────────────────────────────────────────────
        private var selectionStartPdf    = PointF()    // in PDF coordinates
        private var selectionEndPdf      = PointF()    // in PDF coordinates
        private var liveSelectionRects   = mutableListOf<RectF>()  // PDF-space word rects
        private var isSelecting          = false
        private var isDragging           = false
        private val DRAG_THRESHOLD_PX    = 12f * resources.displayMetrics.density

        // ── Handle state ─────────────────────────────────────────────────────
        private var startHandle: SelectionHandleView? = null
        private var endHandle:   SelectionHandleView? = null
        private var activeHandle: SelectionHandleView? = null
        private var handleOppositeAnchorPdf = PointF()  // fixed anchor (PDF coords) when dragging a handle

        // ── Preview animation ────────────────────────────────────────────────
        private var previewAlpha         = 0f
        private var previewAnimator: ValueAnimator? = null

        // ── Cached word list for snapping ────────────────────────────────────
        private var pageWords: List<WordBounds>? = null   // loaded lazily on first interaction

        // ── RTL flag ────────────────────────────────────────────────────────
        private var isRTL                = false

        // ── Paints ──────────────────────────────────────────────────────────
        private val drawPaint = Paint().apply {
            strokeWidth = 5f; style = Paint.Style.STROKE
            strokeJoin = Paint.Join.ROUND; strokeCap = Paint.Cap.ROUND; isAntiAlias = true
        }
        private val previewFillPaint  = Paint(Paint.ANTI_ALIAS_FLAG).apply { style = Paint.Style.FILL }
        private val previewStrokePaint = Paint(Paint.ANTI_ALIAS_FLAG).apply { style = Paint.Style.STROKE; strokeWidth = 2f }
        private val searchAllPaint    = Paint().apply { color = searchAllColor;    style = Paint.Style.FILL }
        private val searchCurPaint    = Paint().apply { color = searchCurrentColor; style = Paint.Style.FILL }

        // ── Scale helper ─────────────────────────────────────────────────────
        private fun getScale(): Float = if (width == 0) 1f else pdfWidth.toFloat() / width.toFloat()

        // ─────────────────────────────────────────────────────────────────────
        // Gesture Detectors
        // ─────────────────────────────────────────────────────────────────────

        private val gestureDetector = GestureDetector(context, object : GestureDetector.SimpleOnGestureListener() {

            // Single tap → annotate word at tap point
            override fun onSingleTapConfirmed(e: MotionEvent): Boolean {
                val scale = getScale()
                val px = e.x * scale; val py = e.y * scale

                return when (currentTool) {
                    "text" -> {
                        val locRv = IntArray(2)
                        recyclerView.getLocationOnScreen(locRv)
                        val physX = e.rawX - locRv[0]
                        val physY = e.rawY - locRv[1]
                        val density = resources.displayMetrics.density
                        val logicalX = physX / density
                        val logicalY = physY / density
                        
                        methodChannel.invokeMethod("onPdfTapped", mapOf("x" to logicalX, "y" to logicalY, "pageIndex" to pageIndex))
                        true
                    }
                    "highlight", "underline" -> {
                        triggerHaptic(HapticStyle.LIGHT)
                        snapWordAtPoint(px, py)
                        true
                    }
                    else -> false
                }
            }

            // Double tap → sentence selection
            override fun onDoubleTap(e: MotionEvent): Boolean {
                if (currentTool != "highlight" && currentTool != "underline") return false
                val scale = getScale()
                val px = e.x * scale; val py = e.y * scale
                triggerHaptic(HapticStyle.HEAVY)
                snapSentenceAtPoint(px, py)
                return true
            }

            // Long press → anchor word + enter drag mode
            override fun onLongPress(e: MotionEvent) {
                if (currentTool != "highlight" && currentTool != "underline") return
                val scale = getScale()
                val px = e.x * scale; val py = e.y * scale
                triggerHaptic(HapticStyle.MEDIUM)
                startLongPressSelection(px, py)
            }
        })

        // ─────────────────────────────────────────────────────────────────────
        // Touch dispatch
        // ─────────────────────────────────────────────────────────────────────

        override fun onTouchEvent(event: MotionEvent?): Boolean {
            event ?: return super.onTouchEvent(null)

            // If a handle is active, route all touches to handle dragging
            if (activeHandle != null) {
                handleTouchForHandleDrag(event); return true
            }

            // Let GestureDetector handle tap/double-tap/long-press
            if (gestureDetector.onTouchEvent(event)) return true
            if (currentTool == "none") return super.onTouchEvent(event)

            val scale = getScale()
            val px = event.x * scale; val py = event.y * scale

            when (event.action) {
                MotionEvent.ACTION_DOWN -> {
                    when (currentTool) {
                        "draw" -> {
                            currentDrawingPath = Path().apply { moveTo(event.x, event.y) }
                            currentDrawingPoints.clear()
                            currentDrawingPoints.add(PointF(px, py))
                        }
                        "highlight", "underline" -> {
                            selectionStartPdf.set(px, py)
                            selectionEndPdf.set(px, py)
                            isSelecting = false; isDragging = false
                            liveSelectionRects.clear()
                        }
                    }
                    invalidate(); return true
                }

                MotionEvent.ACTION_MOVE -> {
                    when (currentTool) {
                        "draw" -> {
                            currentDrawingPath.lineTo(event.x, event.y)
                            currentDrawingPoints.add(PointF(px, py))
                        }
                        "highlight", "underline" -> {
                            val dx = px - selectionStartPdf.x
                            val dy = py - selectionStartPdf.y
                            if (!isDragging && Math.hypot(dx.toDouble(), dy.toDouble()) > DRAG_THRESHOLD_PX) {
                                isDragging = true; isSelecting = true
                                fadeInPreview()
                            }
                            if (isDragging) {
                                selectionEndPdf.set(px, py)
                                updateLiveWordSelection(selectionStartPdf, selectionEndPdf)
                            }
                        }
                    }
                    invalidate(); return true
                }

                MotionEvent.ACTION_UP, MotionEvent.ACTION_CANCEL -> {
                    when (currentTool) {
                        "draw" -> {
                            if (currentDrawingPoints.isNotEmpty()) {
                                addAnnotation(Annotation(pageIndex, "draw", 0f, 0f, 0f, 0f, null, drawColor, ArrayList(currentDrawingPoints)))
                            }
                            currentDrawingPath = Path(); currentDrawingPoints.clear()
                        }
                        "highlight", "underline" -> {
                            if (isDragging && liveSelectionRects.isNotEmpty()) {
                                // Show handles briefly then commit
                                showHandlesForRects(liveSelectionRects)
                                mainHandler.postDelayed({
                                    commitLiveSelection()
                                }, 380)
                            }
                            isSelecting = false; isDragging = false
                        }
                    }
                    invalidate(); return true
                }
            }
            return true
        }

        // ─────────────────────────────────────────────────────────────────────
        // Long-press selection start
        // ─────────────────────────────────────────────────────────────────────

        private fun startLongPressSelection(px: Float, py: Float) {
            selectionStartPdf.set(px, py)
            selectionEndPdf.set(px, py)
            isSelecting = true; isDragging = true
            ensurePageWords {
                val word = wordAtPoint(px, py)
                if (word != null) {
                    isRTL = detectRTL(word.text)
                    liveSelectionRects = mutableListOf(RectF(word.rect))
                    fadeInPreview()
                    invalidate()
                    showHandlesForRects(liveSelectionRects)
                }
            }
        }

        // ─────────────────────────────────────────────────────────────────────
        // Handle touch routing
        // ─────────────────────────────────────────────────────────────────────

        private fun handleTouchForHandleDrag(event: MotionEvent) {
            val scale = getScale()
            // Convert screen touch to this view's coordinate space
            // We need to map from the global screen position to view position
            val location = IntArray(2); getLocationOnScreen(location)
            val localX = (event.rawX - location[0]) * scale
            val localY = (event.rawY - location[1]) * scale

            when (event.action) {
                MotionEvent.ACTION_MOVE -> {
                    // Snap to nearest word
                    ensurePageWords {
                        val snapped = wordAtPoint(localX, localY) ?: return@ensurePageWords
                        val opp     = handleOppositeAnchorPdf
                        val fromPt: PointF
                        val toPt:   PointF
                        if (activeHandle?.isStart == true) {
                            fromPt = if (isRTL) PointF(snapped.rect.right, snapped.rect.centerY())
                                               else PointF(snapped.rect.left, snapped.rect.centerY())
                            toPt   = PointF(opp.x, opp.y)
                        } else {
                            fromPt = PointF(opp.x, opp.y)
                            toPt   = if (isRTL) PointF(snapped.rect.left, snapped.rect.centerY())
                                               else PointF(snapped.rect.right, snapped.rect.centerY())
                        }
                        updateLiveWordSelection(fromPt, toPt)
                        repositionHandles()
                        invalidate()
                    }
                }
                MotionEvent.ACTION_UP, MotionEvent.ACTION_CANCEL -> {
                    commitLiveSelection()
                    activeHandle = null
                }
            }
        }

        // ─────────────────────────────────────────────────────────────────────
        // Word snapping helpers
        // ─────────────────────────────────────────────────────────────────────

        /** Loads word bounding boxes for this page, caches the result. */
        private fun ensurePageWords(onReady: () -> Unit) {
            if (pageWords != null) { onReady(); return }
            interactionExecutor.execute {
                val doc = interactionDocument ?: return@execute
                val words = mutableListOf<WordBounds>()
                try {
                    synchronized(pdfBoxLock) {
                        val collector = PageTextCollector(pageIndex)
                        collector.getText(doc)
                        val positions = collector.positions
                        if (positions.isEmpty()) { mainHandler.post(onReady); return@execute }

                        // Group positions into words (split on whitespace)
                        var wordStart = 0
                        var sb = StringBuilder()
                        var minX = Float.MAX_VALUE; var maxX = -Float.MAX_VALUE
                        var minY = Float.MAX_VALUE; var maxY = -Float.MAX_VALUE

                        fun flushWord() {
                            if (sb.isNotEmpty() && minX < maxX && minY < maxY) {
                                words.add(WordBounds(RectF(minX, minY, maxX, maxY), sb.toString(), wordStart, wordStart + sb.length - 1))
                            }
                            sb = StringBuilder(); minX = Float.MAX_VALUE; maxX = -Float.MAX_VALUE
                            minY = Float.MAX_VALUE; maxY = -Float.MAX_VALUE
                        }

                        positions.forEachIndexed { i, pos ->
                            val ch = pos.unicode?.firstOrNull() ?: return@forEachIndexed
                            if (ch == ' ' || ch == '\t' || ch == '\n' || ch == '\r') {
                                flushWord(); wordStart = i + 1
                            } else {
                                if (sb.isEmpty()) wordStart = i
                                sb.append(ch)
                                minX = minOf(minX, pos.xDirAdj)
                                maxX = maxOf(maxX, pos.xDirAdj + pos.width)
                                minY = minOf(minY, pos.yDirAdj - pos.height)
                                maxY = maxOf(maxY, pos.yDirAdj)
                            }
                        }
                        flushWord()
                    }
                } catch (e: Exception) { e.printStackTrace() }
                pageWords = words
                mainHandler.post(onReady)
            }
        }

        /** Returns the word whose bounding box (expanded by ~10% for tolerance) contains (px, py). */
        private fun wordAtPoint(px: Float, py: Float): WordBounds? {
            val words = pageWords ?: return null
            // Expand each rect a little for hit testing
            val tolerance = 8f
            // First pass: exact contains
            words.firstOrNull { it.rect.contains(px, py) }?.let { return it }
            // Second pass: with tolerance
            return words.minByOrNull { w ->
                val cx = w.rect.centerX(); val cy = w.rect.centerY()
                Math.hypot((cx - px).toDouble(), (cy - py).toDouble()).toFloat()
                    .let { if (it < w.rect.width() + tolerance + w.rect.height() + tolerance) it else Float.MAX_VALUE }
            }
        }

        /** Computes liveSelectionRects as a list of per-line word-snapped RectFs covering start→end. */
        private fun updateLiveWordSelection(startPdf: PointF, endPdf: PointF) {
            val words = pageWords
            if (words == null) {
                // Fallback: raw rect while words are loading
                val left = minOf(startPdf.x, endPdf.x); val top  = minOf(startPdf.y, endPdf.y)
                val right = maxOf(startPdf.x, endPdf.x); val bot  = maxOf(startPdf.y, endPdf.y)
                liveSelectionRects = mutableListOf(RectF(left, top, right, bot))
                ensurePageWords { updateLiveWordSelection(startPdf, endPdf); invalidate() }
                return
            }

            // Determine selection direction
            val selTop    = minOf(startPdf.y, endPdf.y)
            val selBottom = maxOf(startPdf.y, endPdf.y)
            val selLeft   = if (startPdf.y <= endPdf.y) startPdf.x else endPdf.x
            val selRight  = if (startPdf.y <= endPdf.y) endPdf.x   else startPdf.x

            // Collect all words that overlap with the selection band
            val selected = words.filter { w ->
                val wTop = w.rect.top; val wBot = w.rect.bottom; val wLeft = w.rect.left; val wRight = w.rect.right
                // Must overlap vertically
                if (wBot < selTop - 5f || wTop > selBottom + 5f) return@filter false
                // On first line: must start after selLeft (for LTR) or before selRight (RTL)
                val onFirstLine = Math.abs(wTop - selTop) < w.rect.height()
                val onLastLine  = Math.abs(wBot - selBottom) < w.rect.height()
                when {
                    onFirstLine && onLastLine -> RectF.intersects(w.rect, RectF(selLeft, selTop, selRight, selBottom))
                    onFirstLine -> if (isRTL) wLeft <= selLeft + w.rect.width() else wRight >= selLeft - w.rect.width()
                    onLastLine  -> if (isRTL) wRight >= selRight - w.rect.width() else wLeft <= selRight + w.rect.width()
                    else        -> true  // middle lines: all words
                }
            }

            if (selected.isEmpty()) { liveSelectionRects = mutableListOf(); return }

            // Group into lines by Y coordinate and merge into line rects
            val lineGroups = mutableMapOf<Float, MutableList<WordBounds>>()
            for (w in selected) {
                val lineKey = Math.round(w.rect.centerY() / 5f) * 5f
                lineGroups.getOrPut(lineKey) { mutableListOf() }.add(w)
            }

            liveSelectionRects = lineGroups.map { (_, lineWords) ->
                val minX = lineWords.minOf { it.rect.left }
                val maxX = lineWords.maxOf { it.rect.right }
                val minY = lineWords.minOf { it.rect.top }
                val maxY = lineWords.maxOf { it.rect.bottom }
                RectF(minX, minY, maxX, maxY)
            }.sortedBy { it.top }.toMutableList()

            // Detect RTL from selected text
            isRTL = selected.any { detectRTL(it.text) }
        }

        // ─────────────────────────────────────────────────────────────────────
        // Single-word tap annotation (replaces old snapToText)
        // ─────────────────────────────────────────────────────────────────────

        private fun snapWordAtPoint(px: Float, py: Float) {
            ensurePageWords {
                val word = wordAtPoint(px, py)
                if (word != null) {
                    isRTL = detectRTL(word.text)
                    liveSelectionRects = mutableListOf(RectF(word.rect))
                    showHandlesForRects(liveSelectionRects)
                    fadeInPreview(); invalidate()
                    mainHandler.postDelayed({ commitLiveSelection() }, 320)
                } else {
                    // Fallback to PDFBox TextLocator
                    interactionExecutor.execute {
                        val doc = interactionDocument ?: return@execute
                        try {
                            synchronized(pdfBoxLock) {
                                val locator = TextLocator(pageIndex, px, py)
                                locator.getTextPositions(doc)
                                val bounds = locator.bestMatch
                                mainHandler.post {
                                    if (bounds != null) {
                                        liveSelectionRects = mutableListOf(bounds)
                                        showHandlesForRects(liveSelectionRects)
                                        fadeInPreview(); invalidate()
                                        mainHandler.postDelayed({ commitLiveSelection() }, 320)
                                    }
                                }
                            }
                        } catch (e: Exception) { e.printStackTrace() }
                    }
                }
            }
        }

        // ─────────────────────────────────────────────────────────────────────
        // Sentence selection on double-tap
        // ─────────────────────────────────────────────────────────────────────

        private fun snapSentenceAtPoint(px: Float, py: Float) {
            interactionExecutor.execute {
                val doc = interactionDocument ?: return@execute
                try {
                    synchronized(pdfBoxLock) {
                        val collector = PageTextCollector(pageIndex)
                        collector.getText(doc)
                        val positions = collector.positions
                        if (positions.isEmpty()) return@execute

                        val rawChars = positions.map { it.unicode?.firstOrNull() ?: '\u0000' }
                        val fullText = String(rawChars.toCharArray())

                        // Find the position index closest to the tap point
                        val tappedIdx = positions.indexOfFirst { pos ->
                            val x0 = pos.xDirAdj; val x1 = x0 + pos.width
                            val y0 = pos.yDirAdj - pos.height; val y1 = pos.yDirAdj
                            px in x0..x1 && py in y0..y1
                        }.takeIf { it >= 0 }
                            ?: positions.minByOrNull { pos ->
                                val cx = pos.xDirAdj + pos.width / 2
                                val cy = pos.yDirAdj - pos.height / 2
                                Math.hypot((cx - px).toDouble(), (cy - py).toDouble())
                            }?.let { positions.indexOf(it) }
                            ?: return@execute

                        // Walk backward to sentence start
                        val sentenceTerminators = setOf('.', '!', '?', '؟', '\n')
                        var sentStart = tappedIdx
                        var i = tappedIdx - 1
                        while (i >= 0) {
                            if (rawChars[i] in sentenceTerminators) { sentStart = i + 1; break }
                            sentStart = i; i--
                        }
                        // Skip leading whitespace
                        while (sentStart < rawChars.size && (rawChars[sentStart] == ' ' || rawChars[sentStart] == '\t')) sentStart++

                        // Walk forward to sentence end
                        var sentEnd = tappedIdx
                        while (sentEnd < rawChars.size) {
                            if (rawChars[sentEnd] in sentenceTerminators) { sentEnd++; break }
                            sentEnd++
                        }
                        sentEnd = (sentEnd - 1).coerceAtMost(rawChars.size - 1)

                        // Compute bounding rects per line
                        val slice = positions.subList(sentStart, sentEnd + 1)
                        val lineGroups = mutableMapOf<Float, MutableList<TextPosition>>()
                        for (pos in slice) {
                            val key = Math.round(pos.yDirAdj / 5f) * 5f
                            lineGroups.getOrPut(key) { mutableListOf() }.add(pos)
                        }
                        val rects = lineGroups.map { (_, linePositions) ->
                            var minX = Float.MAX_VALUE; var maxX = -Float.MAX_VALUE
                            var minY = Float.MAX_VALUE; var maxY = -Float.MAX_VALUE
                            for (pos in linePositions) {
                                minX = minOf(minX, pos.xDirAdj); maxX = maxOf(maxX, pos.xDirAdj + pos.width)
                                minY = minOf(minY, pos.yDirAdj - pos.height); maxY = maxOf(maxY, pos.yDirAdj)
                            }
                            RectF(minX, minY, maxX, maxY)
                        }.sortedBy { it.top }

                        if (rects.isEmpty()) return@execute
                        val sentText = fullText.substring(sentStart, (sentEnd + 1).coerceAtMost(fullText.length))

                        mainHandler.post {
                            isRTL = detectRTL(sentText)
                            liveSelectionRects = rects.toMutableList()
                            showHandlesForRects(liveSelectionRects)
                            fadeInPreview(); invalidate()
                            mainHandler.postDelayed({ commitLiveSelection() }, 400)
                        }
                    }
                } catch (e: Exception) { e.printStackTrace() }
            }
        }

        // ─────────────────────────────────────────────────────────────────────
        // Commit live selection → annotation(s)
        // ─────────────────────────────────────────────────────────────────────

        private fun commitLiveSelection() {
            val rects = liveSelectionRects.toList()
            if (rects.isEmpty()) { fadeOutPreview(); removeHandles(); return }

            for (rect in rects) {
                val yOffset = if (currentTool == "highlight") 0f else rect.height() - 2f
                addAnnotation(Annotation(
                    pageIndex, currentTool,
                    rect.left, rect.top + yOffset,
                    rect.width(), if (currentTool == "highlight") rect.height() else 4f,
                    null,
                    if (currentTool == "highlight") highlightColor else underlineColor
                ))
            }
            liveSelectionRects.clear()
            fadeOutPreview()
            removeHandles()
            invalidate()
        }

        // ─────────────────────────────────────────────────────────────────────
        // Selection Handles
        // ─────────────────────────────────────────────────────────────────────

        private fun showHandlesForRects(rects: List<RectF>) {
            if (rects.isEmpty()) return
            removeHandles()

            val color = if (currentTool == "highlight") highlightColor else underlineColor
            val scale = getScale()

            val sH = SelectionHandleView(context, true)
            val eH = SelectionHandleView(context, false)
            sH.setColor(color); eH.setColor(color)

            // The parent for handles is the AnnotationImageView's parent LinearLayout parent
            // We add them on top of the RecyclerView via a FrameLayout overlay technique:
            // simplest: use the recyclerView's parent.
            // Actually, we attach them directly to this ImageView by overriding onDraw drawing
            // OR we store their positions and draw them in onDraw (simpler, no extra views).
            // We'll draw them in onDraw using the stored positions — pure canvas approach.

            // Instead of real Views (complex RTL parenting), draw handles on canvas:
            startHandle = sH; endHandle = eH
            positionHandlesForRects(rects)
            sH.animateAppear(); eH.animateAppear()
        }

        private fun positionHandlesForRects(rects: List<RectF>) {
            if (rects.isEmpty()) return
            val first = rects.first(); val last = rects.last()
            val scale = getScale()

            // Start handle: top-left of first rect (RTL: top-right)
            val sH = startHandle ?: return; val eH = endHandle ?: return
            sH.anchorX = if (isRTL) first.right / scale else first.left / scale
            sH.anchorY = first.top / scale
            eH.anchorX = if (isRTL) last.left / scale  else last.right / scale
            eH.anchorY = last.bottom / scale

            // Store opposite anchor for handle dragging (in PDF coords)
            // this is used when a handle drag begins
        }

        private fun repositionHandles() {
            positionHandlesForRects(liveSelectionRects)
            invalidate()
        }

        private fun removeHandles() {
            startHandle?.animateDisappear(); startHandle = null
            endHandle?.animateDisappear();   endHandle   = null
            activeHandle = null
        }

        // Detect which handle was touched (in view coordinates)
        private fun hitTestHandle(viewX: Float, viewY: Float): SelectionHandleView? {
            val touch = 40f * resources.displayMetrics.density / getScale()  // hit area
            startHandle?.let { h ->
                if (Math.abs(h.anchorX - viewX / getScale()) < touch &&
                    Math.abs(h.anchorY - viewY / getScale()) < touch) return h
            }
            endHandle?.let { h ->
                if (Math.abs(h.anchorX - viewX / getScale()) < touch &&
                    Math.abs(h.anchorY - viewY / getScale()) < touch) return h
            }
            return null
        }

        // ─────────────────────────────────────────────────────────────────────
        // Preview animation
        // ─────────────────────────────────────────────────────────────────────

        private fun fadeInPreview() {
            previewAnimator?.cancel()
            previewAnimator = ValueAnimator.ofFloat(previewAlpha, 1f).apply {
                duration = 120; interpolator = DecelerateInterpolator()
                addUpdateListener { previewAlpha = it.animatedValue as Float; invalidate() }
                start()
            }
        }

        private fun fadeOutPreview() {
            previewAnimator?.cancel()
            previewAnimator = ValueAnimator.ofFloat(previewAlpha, 0f).apply {
                duration = 200; interpolator = DecelerateInterpolator()
                addUpdateListener { previewAlpha = it.animatedValue as Float; invalidate() }
                start()
            }
        }

        // ─────────────────────────────────────────────────────────────────────
        // RTL detection
        // ─────────────────────────────────────────────────────────────────────

        private fun detectRTL(text: String): Boolean {
            for (c in text) {
                if (c == ' ' || c == '\t') continue
                return ArabicNormalizer.isArabic(c) || (c.code in 0x0590..0x05FF) // Arabic or Hebrew
            }
            return false
        }

        // ─────────────────────────────────────────────────────────────────────
        // onDraw — renders all layers
        // ─────────────────────────────────────────────────────────────────────

        override fun onDraw(canvas: Canvas) {
            super.onDraw(canvas)
            val scale = getScale()
            if (scale == 0f) return
            val inv = 1f / scale

            // ── Search highlights ────────────────────────────────────────────
            for (i in searchResults.indices) {
                val m = searchResults[i]; if (m.pageIndex != pageIndex) continue
                val paint = if (i == currentSearchIndex) searchCurPaint else searchAllPaint
                canvas.drawRect(m.rect.left * inv, m.rect.top * inv, m.rect.right * inv, m.rect.bottom * inv, paint)
            }

            // ── Committed annotations ────────────────────────────────────────
            for (anno in undoStack) {
                if (anno.pageIndex != pageIndex) continue
                when (anno.type) {
                    "text" -> {
                        val tp = Paint().apply { color = anno.color; textSize = anno.fontSize * inv; isFakeBoldText = true }
                        canvas.drawText(anno.text ?: "", anno.x * inv, anno.y * inv, tp)
                    }
                    "highlight" -> {
                        val p = Paint().apply { color = anno.color; alpha = 100; style = Paint.Style.FILL }
                        canvas.drawRect(anno.x * inv, anno.y * inv, (anno.x + anno.w) * inv, (anno.y + anno.h) * inv, p)
                    }
                    "underline" -> {
                        val p = Paint().apply { color = anno.color; strokeWidth = 2f * inv; style = Paint.Style.STROKE }
                        canvas.drawLine(anno.x * inv, (anno.y + anno.h) * inv, (anno.x + anno.w) * inv, (anno.y + anno.h) * inv, p)
                    }
                    "draw" -> {
                        val points = anno.points ?: continue; if (points.size < 2) continue
                        val p = Paint(drawPaint).apply { color = anno.color; strokeWidth = 2f * inv }
                        val path = Path().apply {
                            moveTo(points[0].x * inv, points[0].y * inv)
                            for (k in 1 until points.size) lineTo(points[k].x * inv, points[k].y * inv)
                        }
                        canvas.drawPath(path, p)
                    }
                }
            }

            // ── Active draw stroke ───────────────────────────────────────────
            canvas.drawPath(currentDrawingPath, drawPaint.apply { color = drawColor; strokeWidth = 5f })

            // ── Live selection preview ───────────────────────────────────────
            if (liveSelectionRects.isNotEmpty() && previewAlpha > 0f) {
                val baseColor = if (currentTool == "highlight") highlightColor else underlineColor
                previewFillPaint.color   = Color.argb((70 * previewAlpha).toInt(),  Color.red(baseColor), Color.green(baseColor), Color.blue(baseColor))
                previewStrokePaint.color = Color.argb((160 * previewAlpha).toInt(), Color.red(baseColor), Color.green(baseColor), Color.blue(baseColor))
                previewStrokePaint.strokeWidth = 2f * inv
                for (r in liveSelectionRects) {
                    val dr = RectF(r.left * inv, r.top * inv, r.right * inv, r.bottom * inv)
                    canvas.drawRoundRect(dr, 3f * inv, 3f * inv, previewFillPaint)
                    canvas.drawRoundRect(dr, 3f * inv, 3f * inv, previewStrokePaint)
                }
            }

            // ── Selection handles (drawn on canvas) ──────────────────────────
            drawHandleOnCanvas(canvas, startHandle, inv)
            drawHandleOnCanvas(canvas, endHandle,   inv)
        }

        private fun drawHandleOnCanvas(canvas: Canvas, handle: SelectionHandleView?, inv: Float) {
            if (handle == null || handle.alpha == 0f) return
            val density = resources.displayMetrics.density
            val r    = 10f * density * inv
            val stemW = 2f * density * inv
            val stemH = 10f * density * inv
            val cx = handle.anchorX
            val cy = handle.anchorY
            val alpha = (handle.alpha * 255).toInt()

            val color = if (currentTool == "highlight") highlightColor else underlineColor
            val solidColor = Color.argb(alpha, Color.red(color), Color.green(color), Color.blue(color))
            val handlePaint = Paint(Paint.ANTI_ALIAS_FLAG).apply { this.color = solidColor; style = Paint.Style.FILL }
            val shadowPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply { this.color = Color.argb(alpha / 4, 0, 0, 0); style = Paint.Style.FILL }

            if (handle.isStart) {
                // Stem above anchor, circle below stem
                canvas.drawCircle(cx, cy + r * 1.5f, r + density * inv, shadowPaint)  // shadow
                canvas.drawRoundRect(cx - stemW/2, cy - stemH, cx + stemW/2, cy, stemW/2, stemW/2, handlePaint)
                canvas.drawCircle(cx, cy + r, r, handlePaint)
            } else {
                // Circle above anchor, stem below
                canvas.drawCircle(cx, cy - r * 0.5f, r + density * inv, shadowPaint)  // shadow
                canvas.drawCircle(cx, cy - r, r, handlePaint)
                canvas.drawRoundRect(cx - stemW/2, cy, cx + stemW/2, cy + stemH, stemW/2, stemW/2, handlePaint)
            }
        }

        // ─────────────────────────────────────────────────────────────────────
        // Override onTouchEvent to also detect handle taps before gesture detector
        // ─────────────────────────────────────────────────────────────────────

        // We override the ACTION_DOWN case to check handle hit testing first
        private var pendingHandleCheck = false

        override fun dispatchTouchEvent(event: MotionEvent?): Boolean {
            event ?: return super.dispatchTouchEvent(null)
            if (event.action == MotionEvent.ACTION_DOWN && startHandle != null) {
                val hit = hitTestHandle(event.x, event.y)
                if (hit != null) {
                    activeHandle = hit
                    triggerHaptic(HapticStyle.LIGHT)
                    // Capture the opposite handle's anchor as the fixed end
                    val opp = if (hit.isStart) endHandle else startHandle
                    handleOppositeAnchorPdf.set(
                        (opp?.anchorX ?: 0f) * getScale(),
                        (opp?.anchorY ?: 0f) * getScale()
                    )
                    return true
                }
            }
            return super.dispatchTouchEvent(event)
        }
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Save PDF (unchanged from original)
    // ─────────────────────────────────────────────────────────────────────────

    private fun setPdfBoxColor(cs: PDPageContentStream, color: Int, isNonStroking: Boolean) {
        val r = (color shr 16) and 0xFF; val g = (color shr 8) and 0xFF; val b = color and 0xFF
        if (isNonStroking) cs.setNonStrokingColor(r, g, b) else cs.setStrokingColor(r, g, b)
    }

    private fun drawMixedText(cs: PDPageContentStream, text: String, x: Float, y: Float,
                               pageHeight: Float, arabicFont: PDFont, latinFont: PDFont,
                               fontSize: Float, color: Int) {
        try {
            cs.beginText(); setPdfBoxColor(cs, color, true); cs.newLineAtOffset(x, pageHeight - y)
            var run = StringBuilder(); var runIsArabic: Boolean? = null
            for (c in text) {
                val ca = ArabicNormalizer.isArabic(c)
                if (runIsArabic == null) { runIsArabic = ca; run.append(c) }
                else if (ca == runIsArabic) { run.append(c) }
                else {
                    cs.setFont(if (runIsArabic!!) arabicFont else latinFont, fontSize)
                    try { cs.showText(run.toString()) } catch (e: Exception) {
                        cs.setFont(if (runIsArabic!!) latinFont else arabicFont, fontSize); cs.showText(run.toString())
                    }
                    run = StringBuilder().append(c); runIsArabic = ca
                }
            }
            if (run.isNotEmpty()) {
                cs.setFont(if (runIsArabic!!) arabicFont else latinFont, fontSize)
                try { cs.showText(run.toString()) } catch (e: Exception) {
                    cs.setFont(if (runIsArabic!!) latinFont else arabicFont, fontSize); cs.showText(run.toString())
                }
            }
            cs.endText()
        } catch (e: Exception) { e.printStackTrace() } finally { cs.close() }
    }

    private fun savePdf(result: MethodChannel.Result) {
        val path = currentPath ?: return result.error("NO_PATH", "No PDF loaded", null)
        interactionExecutor.execute {
            var tempFile: File? = null
            try {
                synchronized(pdfBoxLock) { try { interactionDocument?.close(); interactionDocument = null } catch (_: Exception) {} }
                runCatching { bitmapCache.evictAll(); System.gc(); Thread.sleep(100) }

                val document = PDDocument.load(File(path), MemoryUsageSetting.setupTempFileOnly())
                try {
                    var font: PDFont? = null
                    try { font = PDType0Font.load(document, context.assets.open("flutter_assets/assets/fonts/Arial.ttf")) } catch (_: Exception) {}
                    if (font == null) {
                        for (fp in arrayOf("/system/fonts/Arial.ttf", "/system/fonts/NotoSansArabic-Regular.ttf",
                                           "/system/fonts/NotoNaskhArabic-Regular.ttf", "/system/fonts/DroidSansArabic.ttf")) {
                            val f = File(fp); if (f.exists()) { try { font = PDType0Font.load(document, f); break } catch (_: Exception) {} }
                        }
                    }
                    if (font == null) font = com.tom_roush.pdfbox.pdmodel.font.PDType1Font.HELVETICA_BOLD

                    for (anno in ArrayList(undoStack)) {
                        val page = document.getPage(anno.pageIndex); val pageHeight = page.bBox.height
                        when (anno.type) {
                            "highlight" -> {
                                val cs = PDPageContentStream(document, page, PDPageContentStream.AppendMode.APPEND, true, true)
                                val gs = PDExtendedGraphicsState(); gs.nonStrokingAlphaConstant = 0.5f; gs.blendMode = BlendMode.MULTIPLY
                                cs.setGraphicsStateParameters(gs); setPdfBoxColor(cs, anno.color, true)
                                cs.addRect(anno.x, pageHeight - anno.y - anno.h, anno.w, anno.h); cs.fill(); cs.close()
                            }
                            "underline" -> {
                                val cs = PDPageContentStream(document, page, PDPageContentStream.AppendMode.APPEND, true, true)
                                setPdfBoxColor(cs, anno.color, false); cs.setLineWidth(1.5f)
                                val pdfY = pageHeight - anno.y - anno.h
                                cs.moveTo(anno.x, pdfY); cs.lineTo(anno.x + anno.w, pdfY); cs.stroke(); cs.close()
                            }
                            "text" -> drawMixedText(
                                PDPageContentStream(document, page, PDPageContentStream.AppendMode.APPEND, true, true),
                                ArabicShaper.shape(anno.text ?: ""), anno.x, anno.y, pageHeight,
                                font!!, com.tom_roush.pdfbox.pdmodel.font.PDType1Font.HELVETICA_BOLD, anno.fontSize, anno.color
                            )
                            "draw" -> {
                                val points = anno.points ?: continue
                                if (points.size >= 2) {
                                    val cs = PDPageContentStream(document, page, PDPageContentStream.AppendMode.APPEND, true, true)
                                    setPdfBoxColor(cs, drawColor, false); cs.setLineWidth(2f)
                                    cs.moveTo(points[0].x, pageHeight - points[0].y)
                                    for (k in 1 until points.size) cs.lineTo(points[k].x, pageHeight - points[k].y)
                                    cs.stroke(); cs.close()
                                }
                            }
                        }
                    }
                    tempFile = File.createTempFile("saved_pdf_", ".pdf", context.cacheDir)
                    document.save(tempFile)
                } finally { document.close() }

                val bytes = tempFile.readBytes()
                synchronized(pdfBoxLock) { interactionDocument = PDDocument.load(File(path), MemoryUsageSetting.setupTempFileOnly()) }
                Handler(Looper.getMainLooper()).post { result.success(bytes) }
            } catch (e: Exception) {
                e.printStackTrace()
                try { synchronized(pdfBoxLock) { if (interactionDocument == null) interactionDocument = PDDocument.load(File(path), MemoryUsageSetting.setupTempFileOnly()) } } catch (_: Exception) {}
                Handler(Looper.getMainLooper()).post { result.error("SAVE_ERROR", e.message, null) }
            } finally { tempFile?.delete() }
        }
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Data classes
    // ─────────────────────────────────────────────────────────────────────────

    data class Annotation(
        val pageIndex: Int, val type: String,
        val x: Float, val y: Float, val w: Float, val h: Float,
        val text: String? = null, val color: Int = Color.BLACK,
        val points: List<PointF>? = null,
        val fontSize: Float = 14f
    )

    class SearchMatch(val pageIndex: Int, val rect: RectF)

    // ─────────────────────────────────────────────────────────────────────────
    // Arabic Search Engine (unchanged from original)
    // ─────────────────────────────────────────────────────────────────────────

    private fun searchText(query: String) {
        clearSearch(); if (query.isEmpty()) return
        interactionExecutor.execute {
            val document = interactionDocument ?: return@execute
            val results  = mutableListOf<SearchMatch>()
            try {
                synchronized(pdfBoxLock) {
                    val isArabic  = query.any { ArabicNormalizer.isArabic(it) }
                    val queryNorm = ArabicNormalizer.normalize(query).trim()
                    for (pageIndex in 0 until document.numberOfPages) {
                        val pageMatches = if (isArabic) arabicSearchPage(document, pageIndex, queryNorm)
                                          else          latinSearchPage(document, pageIndex, query)
                        results.addAll(pageMatches)
                    }
                }
                mainHandler.post {
                    searchResults.addAll(results)
                    currentSearchIndex = if (searchResults.isNotEmpty()) 0 else -1
                    if (searchResults.isNotEmpty()) jumpToMatch(searchResults[0])
                    refreshAllViews(); notifySearchResults()
                }
            } catch (e: Exception) { e.printStackTrace() }
        }
    }

    private fun arabicSearchPage(document: PDDocument, pageIndex: Int, queryNorm: String): List<SearchMatch> {
        val collector = PageTextCollector(pageIndex)
        try { collector.getText(document) } catch (e: Exception) { e.printStackTrace(); return emptyList() }
        if (collector.positions.isEmpty()) return emptyList()
        val rawChars = collector.positions.map { it.unicode?.firstOrNull() ?: '\u0000' }
        val mapping  = ArabicNormalizer.buildNormalizationMap(rawChars)
        val pageNorm = mapping.normalizedText
        if (pageNorm.isEmpty()) return emptyList()
        val queryRev      = queryNorm.reversed()
        val queryRevWords = ArabicNormalizer.reverseWords(queryNorm)
        val forwardRanges = findAll(queryNorm, pageNorm)
        if (forwardRanges.isNotEmpty()) return forwardRanges.mapNotNull { rectsFromNormRange(it, mapping, collector.positions, pageIndex) }
        val reversedRanges = mutableListOf<IntRange>()
        reversedRanges.addAll(findAll(queryRev, pageNorm))
        if (queryRevWords != queryNorm && queryRevWords != queryRev) reversedRanges.addAll(findAll(queryRevWords, pageNorm))
        return reversedRanges.mapNotNull { rectsFromNormRange(it, mapping, collector.positions, pageIndex) }.deduplicated()
    }

    private fun latinSearchPage(document: PDDocument, pageIndex: Int, query: String): List<SearchMatch> {
        val collector = PageTextCollector(pageIndex)
        try { collector.getText(document) } catch (e: Exception) { return emptyList() }
        if (collector.positions.isEmpty()) return emptyList()
        val rawChars = collector.positions.map { it.unicode?.firstOrNull() ?: '\u0000' }
        val fullText = String(rawChars.toCharArray()); val lt = fullText.lowercase(); val lq = query.lowercase()
        val results  = mutableListOf<SearchMatch>(); var start = 0
        while (start < lt.length) {
            val idx = lt.indexOf(lq, start); if (idx == -1) break
            val end = idx + lq.length - 1
            val rect = boundsFromPositions(collector.positions, idx, end) ?: continue
            results.add(SearchMatch(pageIndex, rect)); start = idx + 1
        }
        return results
    }

    private fun findAll(pattern: String, text: String): List<IntRange> {
        if (pattern.isEmpty() || text.isEmpty()) return emptyList()
        val lo = text.lowercase(); val lp = pattern.lowercase(); val ranges = mutableListOf<IntRange>(); var i = 0
        while (i <= lo.length - lp.length) { if (lo.startsWith(lp, i)) { ranges.add(i until i + lp.length); i += lp.length } else i++ }
        return ranges
    }

    private fun rectsFromNormRange(normRange: IntRange, mapping: ArabicNormalizer.NormMap,
                                    positions: List<TextPosition>, pageIndex: Int): SearchMatch? {
        val origStart = mapping.normToOrig.getOrNull(normRange.first) ?: return null
        val origEnd   = mapping.normToOrig.getOrNull(normRange.last)  ?: return null
        val rect = boundsFromPositions(positions, minOf(origStart, origEnd), maxOf(origStart, origEnd)) ?: return null
        return SearchMatch(pageIndex, rect)
    }

    private fun boundsFromPositions(positions: List<TextPosition>, start: Int, end: Int): RectF? {
        if (start > end || end >= positions.size || start < 0) return null
        var minX = Float.MAX_VALUE; var maxX = -Float.MAX_VALUE; var minY = Float.MAX_VALUE; var maxY = -Float.MAX_VALUE
        for (i in start..end) {
            val pos = positions[i]
            if (pos.unicode?.trim().isNullOrEmpty() && (end - start) > 0) continue
            minX = minOf(minX, pos.xDirAdj, pos.xDirAdj + pos.width)
            maxX = maxOf(maxX, pos.xDirAdj, pos.xDirAdj + pos.width)
            minY = minOf(minY, pos.yDirAdj - pos.height, pos.yDirAdj)
            maxY = maxOf(maxY, pos.yDirAdj - pos.height, pos.yDirAdj)
        }
        if (minX >= maxX || minY >= maxY) return null
        return RectF(minX, minY, maxX, maxY)
    }

    private fun List<SearchMatch>.deduplicated(): List<SearchMatch> {
        val unique = mutableListOf<SearchMatch>()
        for (m in this) { if (unique.none { it.pageIndex == m.pageIndex && Math.abs(it.rect.left - m.rect.left) < 4f && Math.abs(it.rect.top - m.rect.top) < 4f }) unique.add(m) }
        return unique
    }

    private fun nextSearchResult() {
        if (searchResults.isEmpty()) return
        currentSearchIndex = (currentSearchIndex + 1) % searchResults.size
        jumpToMatch(searchResults[currentSearchIndex]); refreshAllViews(); notifySearchResults()
    }

    private fun previousSearchResult() {
        if (searchResults.isEmpty()) return
        currentSearchIndex = (currentSearchIndex - 1 + searchResults.size) % searchResults.size
        jumpToMatch(searchResults[currentSearchIndex]); refreshAllViews(); notifySearchResults()
    }

    private fun clearSearch() { searchResults.clear(); currentSearchIndex = -1; refreshAllViews(); notifySearchResults() }
    private fun jumpToMatch(match: SearchMatch) { (layoutManager as? LinearLayoutManager)?.scrollToPositionWithOffset(match.pageIndex, 0) }
    private fun notifySearchResults() {
        mainHandler.post { methodChannel.invokeMethod("onSearchResultsChanged", mapOf("current" to currentSearchIndex + 1, "total" to searchResults.size)) }
    }

    // ─────────────────────────────────────────────────────────────────────────
    // PageTextCollector (unchanged)
    // ─────────────────────────────────────────────────────────────────────────

    class PageTextCollector(pageIndex: Int) : PDFTextStripper() {
        val positions = mutableListOf<TextPosition>()
        init { sortByPosition = true; startPage = pageIndex + 1; endPage = pageIndex + 1 }
        override fun processTextPosition(text: TextPosition) { positions.add(text) }
        override fun writeString(text: String?, textPositions: MutableList<TextPosition>?) { }
    }

    // ─────────────────────────────────────────────────────────────────────────
    // TextLocator / TextRangeLocator (unchanged)
    // ─────────────────────────────────────────────────────────────────────────

    class TextLocator(val targetPage: Int, val tapX: Float, val tapY: Float) : PDFTextStripper() {
        var bestMatch: RectF? = null; private var minDist = Float.MAX_VALUE
        init { sortByPosition = true; startPage = targetPage + 1; endPage = targetPage + 1 }
        fun getTextPositions(doc: PDDocument) { try { getText(doc) } catch (e: Exception) { e.printStackTrace() } }
        override fun writeString(text: String?, textPositions: MutableList<TextPosition>?) {
            if (textPositions == null || textPositions.isEmpty()) return
            val word = mutableListOf<TextPosition>()
            for (pos in textPositions) { if (pos.unicode in listOf(" ", "\t", "\n", "\r")) { checkWord(word); word.clear() } else word.add(pos) }
            checkWord(word)
        }
        private fun checkWord(word: List<TextPosition>) {
            if (word.isEmpty()) return
            var minX = Float.MAX_VALUE; var maxX = 0f; var minY = Float.MAX_VALUE; var maxY = 0f
            for (p in word) { minX = minOf(minX, p.xDirAdj); maxX = maxOf(maxX, p.xDirAdj + p.width); minY = minOf(minY, p.yDirAdj - p.height); maxY = maxOf(maxY, p.yDirAdj) }
            val tr = RectF(minX - 20, minY - 15, maxX + 20, maxY + 15)
            if (tr.contains(tapX, tapY)) {
                val dist = Math.abs((minX + maxX) / 2 - tapX) + Math.abs((minY + maxY) / 2 - tapY)
                if (dist < minDist) { minDist = dist; bestMatch = RectF(minX, minY, maxX, maxY) }
            }
        }
    }

    class TextRangeLocator(val targetPage: Int, val x1: Float, val y1: Float, val x2: Float, val y2: Float) : PDFTextStripper() {
        val lineMatches = mutableListOf<RectF>()
        private val selectionRect = RectF(minOf(x1, x2), minOf(y1, y2), maxOf(x1, x2), maxOf(y1, y2))
        init { sortByPosition = true; startPage = targetPage + 1; endPage = targetPage + 1 }
        fun getTextPositions(doc: PDDocument) { try { getText(doc) } catch (e: Exception) { e.printStackTrace() } }
        override fun writeString(text: String?, textPositions: MutableList<TextPosition>?) {
            if (textPositions == null || textPositions.isEmpty()) return
            var minX = Float.MAX_VALUE; var maxX = 0f; var minY = Float.MAX_VALUE; var maxY = 0f; var found = false
            for (pos in textPositions) {
                val cr = RectF(pos.xDirAdj, pos.yDirAdj - pos.height, pos.xDirAdj + pos.width, pos.yDirAdj)
                if (RectF.intersects(selectionRect, cr)) {
                    found = true; minX = minOf(minX, pos.xDirAdj); maxX = maxOf(maxX, pos.xDirAdj + pos.width)
                    minY = minOf(minY, pos.yDirAdj - pos.height); maxY = maxOf(maxY, pos.yDirAdj)
                }
            }
            if (found) lineMatches.add(RectF(minX, minY, maxX, maxY))
        }
    }

    // ─────────────────────────────────────────────────────────────────────────
    // ArabicNormalizer (unchanged from original)
    // ─────────────────────────────────────────────────────────────────────────

    object ArabicNormalizer {
        fun isArabic(c: Char): Boolean {
            val v = c.code
            return (v in 0x0600..0x06FF) || (v in 0x0750..0x077F) ||
                   (v in 0x08A0..0x08FF) || (v in 0xFB50..0xFDFF) || (v in 0xFE70..0xFEFF)
        }
        private val PRESENTATION_TO_BASE: Map<Int, Int> = buildMap {
            val entries = listOf(
                0x0627 to listOf(0xFE8D,0xFE8E),0x0628 to listOf(0xFE8F,0xFE90,0xFE91,0xFE92),
                0x062A to listOf(0xFE95,0xFE96,0xFE97,0xFE98),0x062B to listOf(0xFE99,0xFE9A,0xFE9B,0xFE9C),
                0x062C to listOf(0xFE9D,0xFE9E,0xFE9F,0xFEA0),0x062D to listOf(0xFEA1,0xFEA2,0xFEA3,0xFEA4),
                0x062E to listOf(0xFEA5,0xFEA6,0xFEA7,0xFEA8),0x062F to listOf(0xFEA9,0xFEAA),
                0x0630 to listOf(0xFEAB,0xFEAC),0x0631 to listOf(0xFEAD,0xFEAE),0x0632 to listOf(0xFEAF,0xFEB0),
                0x0633 to listOf(0xFEB1,0xFEB2,0xFEB3,0xFEB4),0x0634 to listOf(0xFEB5,0xFEB6,0xFEB7,0xFEB8),
                0x0635 to listOf(0xFEB9,0xFEBA,0xFEBB,0xFEBC),0x0636 to listOf(0xFEBD,0xFEBE,0xFEBF,0xFEC0),
                0x0637 to listOf(0xFEC1,0xFEC2,0xFEC3,0xFEC4),0x0638 to listOf(0xFEC5,0xFEC6,0xFEC7,0xFEC8),
                0x0639 to listOf(0xFEC9,0xFECA,0xFECB,0xFECC),0x063A to listOf(0xFECD,0xFECE,0xFECF,0xFED0),
                0x0641 to listOf(0xFED1,0xFED2,0xFED3,0xFED4),0x0642 to listOf(0xFED5,0xFED6,0xFED7,0xFED8),
                0x0643 to listOf(0xFED9,0xFEDA,0xFEDB,0xFEDC),0x0644 to listOf(0xFEDD,0xFEDE,0xFEDF,0xFEE0),
                0x0645 to listOf(0xFEE1,0xFEE2,0xFEE3,0xFEE4),0x0646 to listOf(0xFEE5,0xFEE6,0xFEE7,0xFEE8),
                0x0647 to listOf(0xFEE9,0xFEEA,0xFEEB,0xFEEC),0x0648 to listOf(0xFEED,0xFEEE),
                0x064A to listOf(0xFEF1,0xFEF2,0xFEF3,0xFEF4),0x0626 to listOf(0xFE89,0xFE8A,0xFE8B,0xFE8C),
                0x0622 to listOf(0xFE81,0xFE82),0x0623 to listOf(0xFE83,0xFE84),0x0625 to listOf(0xFE87,0xFE88),
                0x0624 to listOf(0xFE85,0xFE86),0x0649 to listOf(0xFEEF,0xFEF0),0x0629 to listOf(0xFE93,0xFE94)
            )
            for ((base, forms) in entries) for (f in forms) put(f, base)
        }
        private val LAM_ALEF: Map<Int,Pair<Int,Int>> = mapOf(
            0xFEF5 to (0x0644 to 0x0622),0xFEF6 to (0x0644 to 0x0622),0xFEF7 to (0x0644 to 0x0623),0xFEF8 to (0x0644 to 0x0623),
            0xFEF9 to (0x0644 to 0x0625),0xFEFA to (0x0644 to 0x0625),0xFEFB to (0x0644 to 0x0627),0xFEFC to (0x0644 to 0x0627)
        )
        private val STRIP_SET: Set<Int> = buildSet {
            addAll(0x064B..0x065F); add(0x0670); addAll(0x06D6..0x06DC); addAll(0x06DF..0x06E4)
            add(0x06E7); add(0x06E8); addAll(0x06EA..0x06ED); addAll(0x0610..0x061A)
            add(0x0640); add(0x200C); add(0x200D); add(0x200E); add(0x200F); add(0xFEFF)
        }
        data class NormMap(val normalizedText: String, val normToOrig: List<Int>)
        fun buildNormalizationMap(chars: List<Char>): NormMap {
            val norm = StringBuilder(); val n2o = mutableListOf<Int>()
            for ((i, c) in chars.withIndex()) {
                val v = c.code
                if (v in STRIP_SET) continue
                val la = LAM_ALEF[v]; if (la != null) { norm.append(la.first.toChar()); n2o.add(i); norm.append(la.second.toChar()); n2o.add(i); continue }
                val base = PRESENTATION_TO_BASE[v]; if (base != null) { norm.append(base.toChar()); n2o.add(i); continue }
                norm.append(c); n2o.add(i)
            }
            val unified = norm.toString()
                .replace('\u0622','\u0627').replace('\u0623','\u0627').replace('\u0625','\u0627').replace('\u0671','\u0627')
                .replace('\u0672','\u0627').replace('\u0673','\u0627').replace('\u0629','\u0647').replace('\u06C1','\u0647')
                .replace('\u0649','\u064A').replace('\u06CC','\u064A').replace('\u06D2','\u064A').replace('\u0624','\u0648').replace('\u0626','\u064A')
            return NormMap(unified, n2o)
        }
        fun normalize(text: String): String = buildNormalizationMap(text.toList()).normalizedText
        fun reverseWords(text: String): String = text.split(" ").reversed().joinToString(" ")
    }

    // ─────────────────────────────────────────────────────────────────────────
    // ArabicShaper (unchanged)
    // ─────────────────────────────────────────────────────────────────────────

    object ArabicShaper {
        private val SHAPING_MAP = mapOf(
            '\u0627' to charArrayOf('\uFE8D','\u0627','\u0627','\uFE8E'),'\u0628' to charArrayOf('\uFE8F','\uFE91','\uFE92','\uFE90'),
            '\u062A' to charArrayOf('\uFE95','\uFE97','\uFE98','\uFE96'),'\u062B' to charArrayOf('\uFE99','\uFE9B','\uFE9C','\uFE9A'),
            '\u062C' to charArrayOf('\uFE9D','\uFE9F','\uFEA0','\uFE9E'),'\u062D' to charArrayOf('\uFEA1','\uFEA3','\uFEA4','\uFEA2'),
            '\u062E' to charArrayOf('\uFEA5','\uFEA7','\uFEA8','\uFEA6'),'\u062F' to charArrayOf('\uFEA9','\u062F','\u062F','\uFEAA'),
            '\u0630' to charArrayOf('\uFEAB','\u0630','\u0630','\uFEAC'),'\u0631' to charArrayOf('\uFEAD','\u0631','\u0631','\uFEAE'),
            '\u0632' to charArrayOf('\uFEAF','\u0632','\u0632','\uFEB0'),'\u0633' to charArrayOf('\uFEB1','\uFEB3','\uFEB4','\uFEB2'),
            '\u0634' to charArrayOf('\uFEB5','\uFEB7','\uFEB8','\uFEB6'),'\u0635' to charArrayOf('\uFEB9','\uFEBB','\uFEBC','\uFEBA'),
            '\u0636' to charArrayOf('\uFEBD','\uFEBF','\uFEC0','\uFEBE'),'\u0637' to charArrayOf('\uFEC1','\uFEC3','\uFEC4','\uFEC2'),
            '\u0638' to charArrayOf('\uFEC5','\uFEC7','\uFEC8','\uFEC6'),'\u0639' to charArrayOf('\uFEC9','\uFECB','\uFECC','\uFECA'),
            '\u063A' to charArrayOf('\uFECD','\uFECF','\uFED0','\uFECE'),'\u0641' to charArrayOf('\uFED1','\uFED3','\uFED4','\uFED2'),
            '\u0642' to charArrayOf('\uFED5','\uFED7','\uFED8','\uFED6'),'\u0643' to charArrayOf('\uFED9','\uFEDB','\uFEDC','\uFEDA'),
            '\u0644' to charArrayOf('\uFEDD','\uFEDF','\uFEE0','\uFEDE'),'\u0645' to charArrayOf('\uFEE1','\uFEE3','\uFEE4','\uFEE2'),
            '\u0646' to charArrayOf('\uFEE5','\uFEE7','\uFEE8','\uFEE6'),'\u0647' to charArrayOf('\uFEE9','\uFEEB','\uFEEC','\uFEEA'),
            '\u0648' to charArrayOf('\uFEED','\u0648','\u0648','\uFEEE'),'\u064A' to charArrayOf('\uFEF1','\uFEF3','\uFEF4','\uFEF2'),
            '\u0626' to charArrayOf('\uFE89','\uFE8B','\uFE8C','\uFE8A'),'\u0622' to charArrayOf('\uFE81','\u0622','\u0622','\uFE82'),
            '\u0623' to charArrayOf('\uFE83','\u0623','\u0623','\uFE84'),'\u0625' to charArrayOf('\uFE87','\u0625','\u0625','\uFE88'),
            '\u0624' to charArrayOf('\uFE85','\u0624','\u0624','\uFE86'),'\u0649' to charArrayOf('\uFEEF','\u0649','\u0649','\uFEF0'),
            '\u0629' to charArrayOf('\uFE93','\u0629','\u0629','\uFE94')
        )
        fun shape(text: String): String {
            if (text.isEmpty()) return text
            val shaped = shapeArabicForms(text)
            val bidi = Bidi(shaped, Bidi.DIRECTION_DEFAULT_LEFT_TO_RIGHT)
            if (!bidi.isMixed && !bidi.isRightToLeft) return shaped
            val runs = mutableListOf<String>()
            for (i in 0 until bidi.runCount) {
                var sub = shaped.substring(bidi.getRunStart(i), bidi.getRunLimit(i))
                if (bidi.getRunLevel(i) % 2 != 0) sub = sub.reversed()
                runs.add(sub)
            }
            return if (bidi.isRightToLeft) runs.reversed().joinToString("") else runs.joinToString("")
        }
        private fun shapeArabicForms(text: String): String {
            val result = StringBuilder()
            for (i in text.indices) {
                val c = text[i]; val forms = SHAPING_MAP[c]
                if (forms == null) { result.append(c); continue }
                val prev = if (i > 0) text[i-1] else null; val next = if (i < text.length-1) text[i+1] else null
                result.append(when {
                    prev != null && canLinkLeft(prev) && next != null && canLinkRight(next) -> forms[2]
                    prev != null && canLinkLeft(prev) -> forms[3]
                    next != null && canLinkRight(next) -> forms[1]
                    else -> forms[0]
                })
            }
            return result.toString()
        }
        private fun canLinkLeft(c: Char)  = SHAPING_MAP[c]?.let { it[1] != c || it[2] != c } ?: false
        private fun canLinkRight(c: Char) = SHAPING_MAP.containsKey(c)
    }
}