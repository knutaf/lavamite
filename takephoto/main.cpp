#include <windows.h>
#include <wrl.h>
#include <stdio.h>
#include <objbase.h>
#include <mfapi.h>
#include <mfidl.h>
#include <mfcaptureengine.h>
#include <wincodec.h>

namespace Mwrl = Microsoft::WRL;

template <class T> void SafeRelease(T **ppT)
{
    if (*ppT)
    {
        (*ppT)->Release();
        *ppT = NULL;
    }
}

// The event callback object.
class CaptureEngineCB : public IMFCaptureEngineOnEventCallback
{
    long m_cRef;

public:
    CaptureEngineCB() : m_cRef(1) {}

    // IUnknown
    STDMETHODIMP QueryInterface(REFIID riid, void** ppv);
    STDMETHODIMP_(ULONG) AddRef();
    STDMETHODIMP_(ULONG) Release();

    // IMFCaptureEngineOnEventCallback
    STDMETHODIMP OnEvent( _In_ IMFMediaEvent* pEvent);
};

class SampleCB : public IMFCaptureEngineOnSampleCallback
{
    long m_cRef;

public:
    SampleCB() : m_cRef(1) {}

    // IUnknown
    STDMETHODIMP QueryInterface(REFIID riid, void** ppv);
    STDMETHODIMP_(ULONG) AddRef();
    STDMETHODIMP_(ULONG) Release();

    STDMETHODIMP OnSample( _In_ IMFSample* pSample);
};

HRESULT CopyAttribute(IMFAttributes *pSrc, IMFAttributes *pDest, const GUID& key)
{
    PROPVARIANT var;
    PropVariantInit( &var );
    HRESULT hr = pSrc->GetItem(key, &var);
    if (SUCCEEDED(hr))
    {
        hr = pDest->SetItem(key, var);
        PropVariantClear(&var);
    }
    return hr;
}

// Creates a compatible video format with a different subtype.

HRESULT CloneVideoMediaType(IMFMediaType *pSrcMediaType, REFGUID guidSubType, IMFMediaType **ppNewMediaType)
{
    IMFMediaType *pNewMediaType = NULL;

    HRESULT hr = MFCreateMediaType(&pNewMediaType);
    if (FAILED(hr))
    {
        goto done;
    }

    hr = pNewMediaType->SetGUID(MF_MT_MAJOR_TYPE, MFMediaType_Video);     
    if (FAILED(hr))
    {
        goto done;
    }

    hr = pNewMediaType->SetGUID(MF_MT_SUBTYPE, guidSubType);
    if (FAILED(hr))
    {
        goto done;
    }

    hr = CopyAttribute(pSrcMediaType, pNewMediaType, MF_MT_FRAME_SIZE);
    if (FAILED(hr))
    {
        goto done;
    }

    hr = CopyAttribute(pSrcMediaType, pNewMediaType, MF_MT_FRAME_RATE);
    if (FAILED(hr))
    {
        goto done;
    }

    hr = CopyAttribute(pSrcMediaType, pNewMediaType, MF_MT_PIXEL_ASPECT_RATIO);
    if (FAILED(hr))
    {
        goto done;
    }

    hr = CopyAttribute(pSrcMediaType, pNewMediaType, MF_MT_INTERLACE_MODE);
    if (FAILED(hr))
    {
        goto done;
    }

    *ppNewMediaType = pNewMediaType;
    (*ppNewMediaType)->AddRef();

done:
    SafeRelease(&pNewMediaType);
    return hr;
}

HRESULT StartPreview(IMFCaptureEngine* pEngine)
{
    IMFCapturePreviewSink* pPreview = NULL;
    IMFCaptureSink *pSink = NULL;
    IMFMediaType *pMediaType = NULL;
    IMFMediaType *pMediaType2 = NULL;
    IMFCaptureSource *pSource = NULL;
    IMFCaptureEngineOnSampleCallback* pCallback = NULL;

    HRESULT hr = S_OK;

    hr = pEngine->GetSink(MF_CAPTURE_ENGINE_SINK_TYPE_PREVIEW, &pSink);
    if (FAILED(hr))
    {
        wprintf(L"failed GetSink: %08X\n", hr);
        goto error;
    }

    hr = pSink->QueryInterface(IID_PPV_ARGS(&pPreview));
    if (FAILED(hr))
    {
        wprintf(L"failed QI preview sink: %08X\n", hr);
        goto done;
    }

    hr = pEngine->GetSource(&pSource);
    if (FAILED(hr))
    {
        wprintf(L"failed GetSource: %08X\n", hr);
        goto done;
    }

    // Configure the video format for the preview sink.
    hr = pSource->GetCurrentDeviceMediaType((DWORD)MF_CAPTURE_ENGINE_PREFERRED_SOURCE_STREAM_FOR_VIDEO_PREVIEW , &pMediaType);
    if (FAILED(hr))
    {
        wprintf(L"failed GetCurrentDeviceMediaType: %08X\n", hr);
        goto done;
    }

    hr = CloneVideoMediaType(pMediaType, MFVideoFormat_RGB32, &pMediaType2);
    if (FAILED(hr))
    {
        wprintf(L"failed CloneVideoMediaType: %08X\n", hr);
        goto done;
    }

    hr = pMediaType2->SetUINT32(MF_MT_ALL_SAMPLES_INDEPENDENT, TRUE);
    if (FAILED(hr))
    {
        wprintf(L"failed SetUINT32 all samples independent: %08X\n", hr);
        goto done;
    }

    // Connect the video stream to the preview sink.
    DWORD dwSinkStreamIndex;
    hr = pPreview->AddStream((DWORD)MF_CAPTURE_ENGINE_PREFERRED_SOURCE_STREAM_FOR_VIDEO_PREVIEW,  pMediaType2, NULL, &dwSinkStreamIndex);
    if (FAILED(hr))
    {
        wprintf(L"failed AddStream video preview: %08X\n", hr);
        goto done;
    }

    pCallback = new SampleCB();
    hr = pPreview->SetSampleCallback(dwSinkStreamIndex, pCallback);
    if (FAILED(hr))
    {
        wprintf(L"failed SetSampleCallback: %08X\n", hr);
        goto done;
    }


    hr = pEngine->StartPreview();

done:
    SafeRelease(&pSink);
    SafeRelease(&pMediaType);
    SafeRelease(&pMediaType2);
    SafeRelease(&pSource);

    return hr;

error:
    goto done;
}

// Creates a JPEG image type that is compatible with a specified video media type.
HRESULT CreatePhotoMediaType(IMFMediaType *pSrcMediaType, UINT32 pxWidth, UINT32 pxHeight, IMFMediaType **ppPhotoMediaType)
{
    *ppPhotoMediaType = NULL;

    Mwrl::ComPtr<IMFMediaType> pPhotoMediaType;

    HRESULT hr = MFCreateMediaType(&pPhotoMediaType);
    if (FAILED(hr))
    {
        wprintf(L"failed MFCreateMediaType: %08X\n", hr);
        goto done;
    }

    hr = pPhotoMediaType->SetGUID(MF_MT_MAJOR_TYPE, MFMediaType_Image);
    if (FAILED(hr))
    {
        wprintf(L"failed SetGUID major type: %08X\n", hr);
        goto done;
    }

    hr = pPhotoMediaType->SetGUID(MF_MT_SUBTYPE, GUID_ContainerFormatJpeg);
    if (FAILED(hr))
    {
        wprintf(L"failed SetGUID sub type: %08X\n", hr);
        goto done;
    }

    if (pxWidth == 0 || pxHeight == 0)
    {
        hr = CopyAttribute(pSrcMediaType, pPhotoMediaType.Get(), MF_MT_FRAME_SIZE);
        if (FAILED(hr))
        {
            wprintf(L"failed copy size attr: %08X\n", hr);
            goto done;
        }
    }
    else
    {
        hr = MFSetAttributeSize(pPhotoMediaType.Get(), MF_MT_FRAME_SIZE, pxWidth, pxHeight);
        if (FAILED(hr))
        {
            wprintf(L"failed setting frame size: %08X\n", hr);
            goto done;
        }
    }

    *ppPhotoMediaType = pPhotoMediaType.Detach();

done:
    return hr;
}

HRESULT TakePhoto(IMFCaptureEngine* pEngine, PCWSTR pszFileName, UINT32 pxWidth, UINT32 pxHeight)
{
    Mwrl::ComPtr<IMFCaptureSink> pSink;
    Mwrl::ComPtr<IMFCapturePhotoSink> pPhoto;
    Mwrl::ComPtr<IMFCaptureSource> pSource;
    Mwrl::ComPtr<IMFMediaType> pMediaType;
    Mwrl::ComPtr<IMFMediaType> pMediaType2;
    bool bHasPhotoStream = true;

    // Get a pointer to the photo sink.
    HRESULT hr = pEngine->GetSink(MF_CAPTURE_ENGINE_SINK_TYPE_PHOTO, &pSink);
    if (FAILED(hr))
    {
        wprintf(L"failed get sink: %08X\n", hr);
        goto done;
    }

    hr = pSink->QueryInterface(IID_PPV_ARGS(&pPhoto));
    if (FAILED(hr))
    {
        wprintf(L"failed qi photo sink: %08X\n", hr);
        goto done;
    }

    hr = pEngine->GetSource(&pSource);
    if (FAILED(hr))
    {
        wprintf(L"failed get source: %08X\n", hr);
        goto done;
    }

    hr = pSource->GetCurrentDeviceMediaType((DWORD)MF_CAPTURE_ENGINE_PREFERRED_SOURCE_STREAM_FOR_PHOTO , &pMediaType);
    if (FAILED(hr))
    {
        wprintf(L"failed get media type: %08X\n", hr);
        goto done;
    }

    //Configure the photo format
    hr = CreatePhotoMediaType(pMediaType.Get(), pxWidth, pxHeight, &pMediaType2);
    if (FAILED(hr))
    {
        wprintf(L"failed create media type: %08X\n", hr);
        goto done;
    }

    hr = pPhoto->RemoveAllStreams();
    if (FAILED(hr))
    {
        wprintf(L"failed remove streams: %08X\n", hr);
        goto done;
    }

    DWORD dwSinkStreamIndex;
    // Try to connect the first still image stream to the photo sink
    if(bHasPhotoStream)
    {
        hr = pPhoto->AddStream((DWORD)MF_CAPTURE_ENGINE_PREFERRED_SOURCE_STREAM_FOR_PHOTO, pMediaType2.Get(), NULL, &dwSinkStreamIndex);
    }

    if(FAILED(hr))
    {
        wprintf(L"failed add stream: %08X\n", hr);
        goto done;
    }

    hr = pPhoto->SetOutputFileName(pszFileName);
    if (FAILED(hr))
    {
        wprintf(L"failed set output filename: %08X\n", hr);
        goto done;
    }

    hr = pEngine->TakePhoto();
    if (FAILED(hr))
    {
        wprintf(L"failed take photo: %08X\n", hr);
        goto done;
    }

    wprintf(L"successfully took photo\n");

done:
    return hr;
}

void Usage(PCWSTR wszComplaint)
{
    if (wszComplaint != nullptr)
    {
        wprintf(L"Error: %s\n", wszComplaint);
    }

    wprintf(L"Usage: takephoto.exe [-st milliseconds] [-w width_pixels] [-h height_pixels] [-o outpath] [-enum] [-d device_index]\n");
}

int
__cdecl
wmain(
    int argc,
    wchar_t* argv[])
{
    HRESULT hr = S_OK;
    IMFActivate** rgpDevices = nullptr;
    UINT32 cDevices = 0;

    bool fEnumDevices = false;
    bool fChooseDevice = false;
    ULONG iDeviceIndex = 0;
    ULONG msStabilityTime = 5000;
    UINT32 pxWidth = 0;
    UINT32 pxHeight = 0;
    PCWSTR wszOutputPath = L"photo.jpg";

    for (int i = 1; i < argc; i++)
    {
        if (wcscmp(argv[i], L"/h") == 0 ||
            wcscmp(argv[i], L"/?") == 0)
        {
            Usage(nullptr);
            hr = S_FALSE;
            goto done;
        }
        else if (wcscmp(argv[i], L"-enum") == 0)
        {
            fEnumDevices = true;
        }
        else if (wcscmp(argv[i], L"-st") == 0)
        {
            i++;
            if (i < argc)
            {
                msStabilityTime = _wtoi(argv[i]);
            }
            else
            {
                Usage(L"need stability time");
                hr = E_INVALIDARG;
                goto error;
            }
        }
        else if (wcscmp(argv[i], L"-w") == 0)
        {
            i++;
            if (i < argc)
            {
                pxWidth = _wtoi(argv[i]);
            }
            else
            {
                Usage(L"need width in pixels");
                hr = E_INVALIDARG;
                goto error;
            }
        }
        else if (wcscmp(argv[i], L"-h") == 0)
        {
            i++;
            if (i < argc)
            {
                pxHeight = _wtoi(argv[i]);
            }
            else
            {
                Usage(L"need height in pixels");
                hr = E_INVALIDARG;
                goto error;
            }
        }
        else if (wcscmp(argv[i], L"-o") == 0)
        {
            i++;
            if (i < argc)
            {
                wszOutputPath = argv[i];
            }
            else
            {
                Usage(L"need output path");
                hr = E_INVALIDARG;
                goto error;
            }
        }
        else if (wcscmp(argv[i], L"-d") == 0)
        {
            i++;
            if (i < argc)
            {
                iDeviceIndex = _wtoi(argv[i]);
                fChooseDevice = true;
            }
            else
            {
                Usage(L"need device index");
                hr = E_INVALIDARG;
                goto error;
            }
        }
        else
        {
            Usage(L"unrecognized argument");
            hr = E_INVALIDARG;
            goto error;
        }
    }

    CoInitializeEx(NULL, COINIT_MULTITHREADED);

    {
        Mwrl::ComPtr<IMFMediaSource> spSource;
        Mwrl::ComPtr<IMFAttributes> spAttributes;
        Mwrl::ComPtr<IMFCaptureEngineClassFactory> spEngineFactory;
        Mwrl::ComPtr<IMFCaptureEngine> spEngine;
        Mwrl::ComPtr<IMFCaptureEngineOnEventCallback> spCallback;

        if (fEnumDevices || fChooseDevice)
        {
            hr = MFCreateAttributes(&spAttributes, 1);
            if (FAILED(hr))
            {
                wprintf(L"failed MFCreateAttributes: %08X\n", hr);
                goto error;
            }

            hr = spAttributes->SetGUID(MF_DEVSOURCE_ATTRIBUTE_SOURCE_TYPE, MF_DEVSOURCE_ATTRIBUTE_SOURCE_TYPE_VIDCAP_GUID);
            if (FAILED(hr))
            {
                wprintf(L"failed SetGUID: %08X\n", hr);
                goto error;
            }

            hr = MFEnumDeviceSources(spAttributes.Get(), &rgpDevices, &cDevices);
            if (FAILED(hr))
            {
                wprintf(L"failed MFEnumDeviceSources: %08X\n", hr);
                goto error;
            }

            if (fEnumDevices)
            {
                for (UINT32 i = 0; i < cDevices; i++)
                {
                    WCHAR wszFriendlyName[500] = L"";
                    UINT32 cchStored = 0;
                    hr = rgpDevices[i]->GetString(MF_DEVSOURCE_ATTRIBUTE_FRIENDLY_NAME, wszFriendlyName, ARRAYSIZE(wszFriendlyName), &cchStored);
                    if (FAILED(hr))
                    {
                        wprintf(L"failed GetString: %08X\n", hr);
                        goto error;
                    }
                    else
                    {
                        wprintf(L"% 2d: %s\n", i, wszFriendlyName);
                    }
                }

                goto done;
            }
        }

        if (fChooseDevice)
        {
            if (iDeviceIndex >= cDevices)
            {
                Usage(L"invalid device index");
                hr = E_INVALIDARG;
                goto error;
            }

            // Create the media source object.
            hr = rgpDevices[iDeviceIndex]->ActivateObject(IID_PPV_ARGS(&spSource));
            if (FAILED(hr))
            {
                wprintf(L"failed ActivateObject: %08X\n", hr);
                goto error;
            }
        }

        hr = CoCreateInstance(
            CLSID_MFCaptureEngineClassFactory,
            nullptr,
            CLSCTX_ALL,
            IID_PPV_ARGS(spEngineFactory.GetAddressOf()));
        if (FAILED(hr))
        {
            wprintf(L"failed create engine factory: %08X\n", hr);
            goto error;
        }

        hr = spEngineFactory->CreateInstance(CLSID_MFCaptureEngine, IID_PPV_ARGS(&spEngine));
        if (FAILED(hr))
        {
            wprintf(L"failed create MFCaptureEngine: %08X\n", hr);
            goto error;
        }

        spCallback.Attach(new (std::nothrow) CaptureEngineCB());
        if (spCallback == NULL)
        {
            wprintf(L"failed make callback: %08X\n", hr);
            hr = E_OUTOFMEMORY;
            goto error;
        }

        hr = spEngine->Initialize(spCallback.Get(), nullptr, nullptr, spSource.Get());
        if (FAILED(hr))
        {
            wprintf(L"failed MFCaptureEngine initialize: %08X\n", hr);
            goto error;
        }

        wprintf(L"Initializing camera...\n");

        Sleep(500);

        hr = StartPreview(spEngine.Get());
        if (FAILED(hr))
        {
            wprintf(L"failed StartPreview: %08X\n", hr);
            goto error;
        }

        Sleep(500);

        wprintf(L"Stabilizing video stream for %d ms...\n", msStabilityTime);

        Sleep(msStabilityTime);

        wprintf(L"Taking photo...\n");

        hr = TakePhoto(spEngine.Get(), wszOutputPath, pxWidth, pxHeight);
        if (FAILED(hr))
        {
            wprintf(L"failed TakePhoto: %08X\n", hr);
            goto error;
        }

        Sleep(1000);

        wprintf(L"Done taking photo...\n");
    }

done:
    if (rgpDevices != nullptr)
    {
        for (UINT32 i = 0; i < cDevices; i++)
        {
            rgpDevices[i]->Release();
            rgpDevices[i] = nullptr;
        }

        CoTaskMemFree(rgpDevices);
        rgpDevices = nullptr;
    }

    CoUninitialize();
    return hr;

error:
    goto done;
}

STDMETHODIMP CaptureEngineCB::QueryInterface(REFIID riid, void** ppv)
{
    HRESULT hr;
    if (riid == __uuidof(IMFCaptureEngineOnEventCallback))
    {
        *ppv = static_cast<IMFCaptureEngineOnEventCallback*>(this);
        hr = S_OK;
    }
    else
    {
        hr = E_NOINTERFACE;
    }
    return hr;
}

STDMETHODIMP_(ULONG) CaptureEngineCB::AddRef()
{
    return InterlockedIncrement(&m_cRef);
}

STDMETHODIMP_(ULONG) CaptureEngineCB::Release()
{
    LONG cRef = InterlockedDecrement(&m_cRef);
    if (cRef == 0)
    {
        delete this;
    }
    return cRef;
}

// Callback method to receive events from the capture engine.
STDMETHODIMP CaptureEngineCB::OnEvent( _In_ IMFMediaEvent* pEvent)
{
    UNREFERENCED_PARAMETER(pEvent);
    return S_OK;
}

STDMETHODIMP SampleCB::QueryInterface(REFIID riid, void** ppv)
{
    HRESULT hr;
    if (riid == __uuidof(IMFCaptureEngineOnSampleCallback))
    {
        *ppv = static_cast<IMFCaptureEngineOnSampleCallback*>(this);
        hr = S_OK;
    }
    else
    {
        hr = E_NOINTERFACE;
    }
    return hr;
}

STDMETHODIMP_(ULONG) SampleCB::AddRef()
{
    return InterlockedIncrement(&m_cRef);
}

STDMETHODIMP_(ULONG) SampleCB::Release()
{
    LONG cRef = InterlockedDecrement(&m_cRef);
    if (cRef == 0)
    {
        delete this;
    }
    return cRef;
}

STDMETHODIMP SampleCB::OnSample(IMFSample* pSample)
{
    UNREFERENCED_PARAMETER(pSample);
    return S_OK;
}
