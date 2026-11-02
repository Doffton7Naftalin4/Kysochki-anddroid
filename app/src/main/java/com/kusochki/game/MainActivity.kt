package com.kusochki.game

import android.app.Activity
import android.content.Intent
import android.net.Uri
import android.os.Bundle
import android.view.View
import android.webkit.ValueCallback
import android.webkit.WebChromeClient
import android.webkit.WebResourceRequest
import android.webkit.WebView
import android.webkit.WebViewClient
import android.webkit.WebSettings
import android.widget.FrameLayout

class MainActivity : Activity() {
    private lateinit var webView: WebView
    private var filePathCallback: ValueCallback<Array<Uri>>? = null
    private val filePickerRequest = 1001

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        window.decorView.systemUiVisibility =
            (View.SYSTEM_UI_FLAG_LAYOUT_STABLE or View.SYSTEM_UI_FLAG_LAYOUT_FULLSCREEN)

        webView = WebView(this)
        webView.layoutParams = FrameLayout.LayoutParams(
            FrameLayout.LayoutParams.MATCH_PARENT,
            FrameLayout.LayoutParams.MATCH_PARENT
        )
        webView.settings.apply {
            javaScriptEnabled = true
            domStorageEnabled = true
            allowFileAccess = true
            allowContentAccess = true
            mediaPlaybackRequiresUserGesture = false
            mixedContentMode = WebSettings.MIXED_CONTENT_NEVER_ALLOW
        }
        webView.webViewClient = object : WebViewClient() {
            override fun shouldOverrideUrlLoading(
                view: WebView?, request: WebResourceRequest?
            ): Boolean = false

            override fun onPageFinished(view: WebView?, url: String?) {
                super.onPageFinished(view, url)
                installCustomPhotosUi()
            }
        }
        webView.webChromeClient = object : WebChromeClient() {
            override fun onShowFileChooser(
                webView: WebView?,
                filePathCallback: ValueCallback<Array<Uri>>?,
                fileChooserParams: FileChooserParams?
            ): Boolean {
                this@MainActivity.filePathCallback?.onReceiveValue(null)
                this@MainActivity.filePathCallback = filePathCallback
                val intent = try {
                    fileChooserParams?.createIntent() ?: Intent(Intent.ACTION_OPEN_DOCUMENT).apply {
                        addCategory(Intent.CATEGORY_OPENABLE)
                        type = "image/*"
                        putExtra(Intent.EXTRA_ALLOW_MULTIPLE, true)
                    }
                } catch (_: Exception) {
                    Intent(Intent.ACTION_OPEN_DOCUMENT).apply {
                        addCategory(Intent.CATEGORY_OPENABLE)
                        type = "*/*"
                        putExtra(Intent.EXTRA_ALLOW_MULTIPLE, true)
                    }
                }
                return try {
                    startActivityForResult(intent, filePickerRequest)
                    true
                } catch (_: Exception) {
                    this@MainActivity.filePathCallback?.onReceiveValue(null)
                    this@MainActivity.filePathCallback = null
                    false
                }
            }
        }
        setContentView(webView)
        webView.loadUrl("file:///android_asset/index.html")
    }

    private fun installCustomPhotosUi() {
        val script = """
            (function() {
              if (window.__kusochkiPhotosInstalled) return;
              window.__kusochkiPhotosInstalled = true;
              const style = document.createElement('style');
              style.textContent = '#kusochki-photo-add{position:fixed;z-index:2147483646;right:12px;bottom:18px;border:0;border-radius:24px;padding:12px 16px;background:#673ab7;color:#fff;font:600 14px sans-serif;box-shadow:0 3px 12px #0005}#kusochki-photo-panel{position:fixed;z-index:2147483647;inset:5%;background:#fff;color:#222;border-radius:16px;padding:16px;overflow:auto;box-shadow:0 0 0 9999px #0009;font:16px sans-serif}#kusochki-photo-grid{display:grid;grid-template-columns:repeat(2,minmax(0,1fr));gap:8px}#kusochki-photo-grid img{width:100%;height:180px;object-fit:contain;background:#eee;border-radius:8px}#kusochki-photo-panel button{padding:10px;margin:4px;border-radius:8px;border:0}';
              document.head.appendChild(style);
              const add = document.createElement('button');
              add.id='kusochki-photo-add'; add.textContent='＋ Добавить фотографии';
              const input = document.createElement('input');
              input.type='file'; input.accept='image/*'; input.multiple=true; input.style.display='none';
              document.body.appendChild(add); document.body.appendChild(input);
              let dbPromise = new Promise((resolve,reject)=>{
                const req=indexedDB.open('KusochkiCustomPhotos',1);
                req.onupgradeneeded=()=>req.result.createObjectStore('photos',{keyPath:'id',autoIncrement:true});
                req.onsuccess=()=>resolve(req.result); req.onerror=()=>reject(req.error);
              });
              async function allPhotos(){
                const db=await dbPromise;
                return new Promise((resolve,reject)=>{const r=db.transaction('photos').objectStore('photos').getAll();r.onsuccess=()=>resolve(r.result||[]);r.onerror=()=>reject(r.error);});
              }
              async function savePhoto(file){
                if(!file.type || !file.type.startsWith('image/')) return;
                const db=await dbPromise;
                return new Promise((resolve,reject)=>{const r=db.transaction('photos','readwrite').objectStore('photos').add({name:file.name||'photo',type:file.type,blob:file,added:Date.now()});r.onsuccess=resolve;r.onerror=()=>reject(r.error);});
              }
              async function showPanel(){
                document.getElementById('kusochki-photo-panel')?.remove();
                const panel=document.createElement('div');panel.id='kusochki-photo-panel';
                panel.innerHTML='<div style="display:flex;align-items:center;justify-content:space-between;gap:8px"><strong>Мои фотографии</strong><button id="kusochki-photo-close">Закрыть</button></div><p>Фотографии сохраняются на этом устройстве.</p><button id="kusochki-photo-select">＋ Выбрать фотографии</button><button id="kusochki-photo-clear">Удалить все</button><div id="kusochki-photo-grid"></div>';
                document.body.appendChild(panel);
                panel.querySelector('#kusochki-photo-close').onclick=()=>panel.remove();
                panel.querySelector('#kusochki-photo-select').onclick=()=>input.click();
                panel.querySelector('#kusochki-photo-clear').onclick=async()=>{
                  const db=await dbPromise;
                  await new Promise((resolve,reject)=>{const r=db.transaction('photos','readwrite').objectStore('photos').clear();r.onsuccess=resolve;r.onerror=()=>reject(r.error);});
                  await renderPhotos();
                };
                async function renderPhotos(){
                  const grid=panel.querySelector('#kusochki-photo-grid');grid.replaceChildren();
                  const photos=await allPhotos();
                  if(!photos.length){grid.textContent='Пока фотографий нет. Нажми «Выбрать фотографии».';return;}
                  photos.forEach(p=>{
                    const card=document.createElement('div');
                    const img=document.createElement('img');img.alt=p.name;img.src=URL.createObjectURL(p.blob);
                    const caption=document.createElement('div');caption.textContent=p.name;
                    card.append(img,caption);grid.appendChild(card);
                  });
                }
                await renderPhotos();
              }
              add.onclick=showPanel;
              input.addEventListener('change',async()=>{
                try {
                  for(const file of Array.from(input.files||[])) await savePhoto(file);
                  input.value='';
                  await showPanel();
                } catch(e) { alert('Не удалось сохранить фотографии. Попробуй выбрать меньше файлов.'); }
              });
            })();
        """.trimIndent()
        webView.evaluateJavascript(script, null)
    }

    @Deprecated("Deprecated in Android API, retained for broad device compatibility")
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        if (requestCode == filePickerRequest) {
            val results = if (resultCode == Activity.RESULT_OK && data != null) {
                val clip = data.clipData
                if (clip != null) {
                    Array(clip.itemCount) { i -> clip.getItemAt(i).uri }
                } else {
                    data.data?.let { arrayOf(it) }
                }
            } else null
            filePathCallback?.onReceiveValue(results)
            filePathCallback = null
        }
    }

    override fun onBackPressed() {
        if (::webView.isInitialized && webView.canGoBack()) webView.goBack()
        else super.onBackPressed()
    }

    override fun onDestroy() {
        if (::webView.isInitialized) webView.destroy()
        super.onDestroy()
    }
}
