module WebGL where

import Prelude ((<$>),bind,discard,pure,Unit,($),(<>),show,(-),unit,(+),(>>=),when,(==))
import Effect (Effect)
import Effect.Ref (Ref, new, write, read)
import Data.Maybe (Maybe(..))
import Data.Tempo (Tempo,origin,timeToCount)
import Data.Time.Duration (Seconds)
import Data.DateTime (DateTime,diff)
import Data.Tuple (Tuple(..))
import Data.Newtype (unwrap)
import Data.Rational (toNumber)
import Data.Map (Map, empty, lookup, insert, fromFoldable)
import Data.TraversableWithIndex (traverseWithIndex)
import Data.Set (toUnfoldable,size)
import Data.Unfoldable1 (range)
import Data.List (zip)
import Data.Int as Int
import Data.Monoid.Disj (Disj(..))

import Signal (SignalInfo)
import Program (Program,programInfo)
import FragmentShader (fragmentShader)
import G (TextureMap)
import WebGLCanvas (WebGLBuffer, WebGLCanvas, WebGLContext, WebGLProgram, WebGLTexture, attachShader, bindBufferArray, bindFrameBuffer, bindTexture, compileShader, configureFrameBufferTextures, createFragmentShader, createProgram, createTexture, createVertexShader, deleteWebGLCanvas, drawDefaultTriangleStrip, drawPostProgram, enableVertexAttribArray, flush, getAttribLocation, getCanvasHeight, getCanvasWidth, getFeedbackTexture, getOutputFrameBuffer, linkProgram, newDefaultTriangleStrip, newWebGLCanvas, setUniform1f, setUniform2f, shaderSource, useProgram, vertexAttribPointer, viewport)
import SharedResources (SharedResources,getTempo,getImage,updateWebcamTexture,Image,Video,GDM,getVideo,getGDM,webcamAspectRatio,_imageAspectRatio,_videoAspectRatio,_gdmAspectRatio)
import AudioAnalyser (AnalyserArray)

type WebGL = {
  sharedResources :: SharedResources,
  glc :: WebGLCanvas,
  triangleStripBuffer :: WebGLBuffer,
  program :: Ref Program,
  programInfo :: Ref SignalInfo, -- note: combined info of past and current programs
  textureMap :: Ref TextureMap,
  shaderSrc :: Ref String,
  shader :: Ref WebGLProgram,
  imageTextures :: Ref (Map String WebGLTexture),
  videoTextures :: Ref (Map String WebGLTexture),
  gdmTextures :: Ref (Map String WebGLTexture),
  fftTexture :: WebGLTexture,
  ifftTexture :: WebGLTexture
  }  

newWebGL :: SharedResources -> Program -> Program -> Effect (Maybe WebGL)
newWebGL sharedResources prog prevProg = do
  mglc <- newWebGLCanvas
  case mglc of 
    Just glc -> do
      triangleStripBuffer <- newDefaultTriangleStrip glc
      tempo <- getTempo sharedResources
      let pInfo' = programInfo prog <> programInfo prevProg
      let textureMap' = calculateTextureMap pInfo'
      Tuple shaderSrc' shader' <- updateFragmentShader glc tempo textureMap' prevProg prog
      program <- new prog
      programInfo <- new pInfo'
      textureMap <- new textureMap'
      shaderSrc <- new shaderSrc'
      shader <- new shader'
      imageTextures <- new empty
      videoTextures <- new empty
      gdmTextures <- new empty
      fftTexture <- createTexture glc
      ifftTexture <- createTexture glc
      let webGL = {
        sharedResources,
        glc,
        triangleStripBuffer,
        program,
        programInfo,
        textureMap,
        shaderSrc,
        shader,
        imageTextures,
        videoTextures,
        gdmTextures,
        fftTexture,
        ifftTexture
        }
      pure $ Just webGL
    Nothing -> pure Nothing
    
updateWebGL :: WebGL -> Program -> Program -> Effect Unit
updateWebGL webGL program previousProgram = do
  tempo <- getTempo webGL.sharedResources
  let pInfo = programInfo program <> programInfo previousProgram
  let textureMap = calculateTextureMap pInfo
  Tuple shaderSrc shader <- updateFragmentShader webGL.glc tempo textureMap previousProgram program 
  write program webGL.program
  write pInfo webGL.programInfo
  write shaderSrc webGL.shaderSrc
  write shader webGL.shader
  write textureMap webGL.textureMap


updateFragmentShader :: WebGLCanvas -> Tempo -> TextureMap -> Program -> Program -> Effect (Tuple String WebGLProgram)
updateFragmentShader glc tempo textureMap oldProg newProg = do
  -- t0 <- nowDateTime
  let shaderSrc = fragmentShader glc.webGL2 tempo textureMap oldProg newProg
  -- t1 <- nowDateTime
  -- log $ " GLSL transpile time = " <> show (diff t1 t0 :: Milliseconds)
  glProg <- createProgram glc
  vShader <- createVertexShader glc
  attachShader glc glProg vShader
  let vShaderSrc = case glc.webGL2 of
                     true -> "#version 300 es\nin vec4 p; void main() { gl_Position = p; }"
                     false -> "attribute vec4 p; void main() { gl_Position = p; }"
  shaderSource glc vShader vShaderSrc
  compileShader glc vShader
  fShader <- createFragmentShader glc
  attachShader glc glProg fShader
  shaderSource glc fShader shaderSrc
  compileShader glc fShader
  linkProgram glc glProg
  flush glc
  
  -- vsStatus <- getShaderParameterCompileStatus glc vShader
  -- vsLog <- getShaderInfoLog glc vShader
  -- log $ " vertex shader status=" <> show vsStatus <> " log: " <> vsLog
  -- fsStatus <- getShaderParameterCompileStatus glc fShader
  -- fsLog <- getShaderInfoLog glc fShader
  -- log $ " fragment shader status=" <> show fsStatus <> " log: " <> fsLog
  -- pLog <- getProgramInfoLog glc glProg
  -- log $ " program log: " <> pLog
  
  pure $ Tuple shaderSrc glProg

  
calculateTextureMap :: SignalInfo -> TextureMap
calculateTextureMap progInfo = { imgs, vids, gdms } 
  where
    imgs = fromFoldable $ zip (toUnfoldable progInfo.imgURLs) (range 4 15)
    vids = fromFoldable $ zip (toUnfoldable progInfo.vidURLs) (range (4 + size progInfo.imgURLs) 15)
    gdms = fromFoldable $ zip (toUnfoldable progInfo.gdmIDs) (range (4 + size progInfo.imgURLs + size progInfo.vidURLs) 15)
     
  
deleteWebGL :: WebGL -> Effect Unit
deleteWebGL webGL = deleteWebGLCanvas webGL.glc


drawWebGL :: WebGL -> DateTime -> Number -> Effect Unit
drawWebGL webGL now brightness = do
  configureFrameBufferTextures webGL.glc
  -- t0 <- nowDateTime
  let glc = webGL.glc
  shader <- read webGL.shader
  useProgram glc shader
  
  -- update time/tempo/resolution uniforms
  w <- getCanvasWidth webGL.glc
  h <- getCanvasHeight webGL.glc
  setUniform2f glc shader "res" (Int.toNumber w) (Int.toNumber h)
  tempo <- getTempo webGL.sharedResources
  setUniform1f glc shader "_time" $ unwrap (diff now (origin tempo) :: Seconds)
  eTime <- _.evalTime <$> read webGL.program
  setUniform1f glc shader "_etime" $ unwrap (diff now eTime :: Seconds)
  setUniform1f glc shader "_cps" $ toNumber $ tempo.freq
  setUniform1f glc shader "_beat" $ toNumber $ timeToCount tempo now
  setUniform1f glc shader "_ebeat" $ toNumber $ timeToCount tempo now - timeToCount tempo eTime
  
  -- update audio analysis uniforms
  read webGL.sharedResources.inputAnalyser.lo >>= setUniform1f glc shader "ilo" 
  read webGL.sharedResources.inputAnalyser.mid >>= setUniform1f glc shader "imid" 
  read webGL.sharedResources.inputAnalyser.hi >>= setUniform1f glc shader "ihi" 
  read webGL.sharedResources.outputAnalyser.lo >>= setUniform1f glc shader "lo" 
  read webGL.sharedResources.outputAnalyser.mid >>= setUniform1f glc shader "mid" 
  read webGL.sharedResources.outputAnalyser.hi >>= setUniform1f glc shader "hi"
  
  -- update special textures (webcam, fft TODO, ifft TODO, feedback)
  ft <- getFeedbackTexture glc
  bindTexture glc shader ft 0 "f"
  programInfo <- read webGL.programInfo
  when (programInfo.fft == Disj true) $ do
    bindTexture glc shader webGL.fftTexture 1 "o"
    _fftToTexture glc.gl webGL.sharedResources.outputAnalyser.analyserArray webGL.fftTexture
  when (programInfo.ifft == Disj true) $ do
    bindTexture glc shader webGL.ifftTexture 2 "i"
    _fftToTexture glc.gl webGL.sharedResources.inputAnalyser.analyserArray webGL.ifftTexture
  updateWebcamTexture webGL.sharedResources glc
  bindTexture glc shader glc.webcamTexture 3 "w"
  webcamAspectRatio webGL.sharedResources >>= setUniform1f glc shader "war"

  -- update image, video, and GDM (display capture) textures
  textureMap <- read webGL.textureMap
  _ <- traverseWithIndex (updateImageTexture webGL shader) textureMap.imgs
  _ <- traverseWithIndex (updateVideoTexture webGL shader) textureMap.vids
  _ <- traverseWithIndex (updateGDMTexture webGL shader) textureMap.gdms
  
  -- draw
  pLoc <- getAttribLocation glc shader "p"
  bindBufferArray glc webGL.triangleStripBuffer
  vertexAttribPointer glc pLoc
  enableVertexAttribArray glc pLoc
  viewport glc 0 0 w h
  -- clearColor glc 0.0 0.0 0.0 0.0
  -- clearColorBuffer glc
  ofb <- getOutputFrameBuffer glc
  bindFrameBuffer glc (Just ofb)
  drawDefaultTriangleStrip glc
  drawPostProgram glc brightness
  -- t1 <- nowDateTime
  -- log $ " draw time = " <> show (diff t1 t0 :: Milliseconds)
  pure unit


updateImageTexture :: WebGL -> WebGLProgram -> String -> Int -> Effect Unit
updateImageTexture webGL shader url n = do
  mImg <- getImage webGL.sharedResources url
  case mImg of
    Nothing -> pure unit
    Just image -> do
      imageTextures <- read webGL.imageTextures
      texture <- case lookup url imageTextures of
                   Just texture -> pure texture
                   Nothing -> do
                     texture <- createTexture webGL.glc
                     _imageToTexture webGL.glc.gl image texture n
                     write (insert url texture imageTextures) webGL.imageTextures
                     pure texture
      bindTexture webGL.glc shader texture n ("t" <> show n)
      _imageAspectRatio image >>= setUniform1f webGL.glc shader ("ar" <> show n)
        
foreign import _imageToTexture :: WebGLContext -> Image -> WebGLTexture -> Int -> Effect Unit


updateVideoTexture :: WebGL -> WebGLProgram -> String -> Int -> Effect Unit
updateVideoTexture webGL shader url n = do
  mVid <- getVideo webGL.sharedResources url
  case mVid of
    Nothing -> pure unit
    Just video -> do
      videoTextures <- read webGL.videoTextures
      texture <- case lookup url videoTextures of
                   Just texture -> pure texture
                   Nothing -> do
                     texture <- createTexture webGL.glc
                     write (insert url texture videoTextures) webGL.videoTextures
                     pure texture
      _videoToTexture webGL.glc.gl video texture n
      bindTexture webGL.glc shader texture n ("t" <> show n)
      _videoAspectRatio video >>= setUniform1f webGL.glc shader ("ar" <> show n)
          
foreign import _videoToTexture :: WebGLContext -> Video -> WebGLTexture -> Int -> Effect Unit


foreign import _fftToTexture :: WebGLContext -> AnalyserArray -> WebGLTexture -> Effect Unit


updateGDMTexture :: WebGL -> WebGLProgram -> String -> Int -> Effect Unit
updateGDMTexture webGL shader x n = do
  mGDM <- getGDM webGL.sharedResources x
  case mGDM of
    Nothing -> pure unit
    Just gdm -> do
      gdmTextures <- read webGL.gdmTextures
      texture <- case lookup x gdmTextures of
                   Just texture -> pure texture
                   Nothing -> do
                     texture <- createTexture webGL.glc
                     write (insert x texture gdmTextures) webGL.gdmTextures
                     pure texture
      _gdmToTexture webGL.glc.gl gdm texture n
      bindTexture webGL.glc shader texture n ("t" <> show n)
      _gdmAspectRatio gdm >>= setUniform1f webGL.glc shader ("ar" <> show n)

foreign import _gdmToTexture :: WebGLContext -> GDM -> WebGLTexture -> Int -> Effect Unit
