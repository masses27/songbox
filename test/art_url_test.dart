import 'package:flutter_test/flutter_test.dart';
import 'package:lyric_music/util/art_url.dart';

void main() {
  const messy = 'http://p1.music.126.net/QUDxxbtWMDew68xCjZPtfg==/109951168975734040.jpg'
      '?imageView=1&thumbnail=800y800&enlarge=1%7CimageView=1&watermark&type=1'
      '&image=b2JqL3dvbkRscw==&dx=0&dy=0%7CimageView=1&thumbnail=140y140&';

  test('网易云封面改写成 https + param，并丢掉那串缩放/水印指令', () {
    expect(artUrl(messy, px: 100),
        'https://p1.music.126.net/QUDxxbtWMDew68xCjZPtfg==/109951168975734040.jpg?param=120y120');
  });

  test('签名路径原样保留，不被解码改写', () {
    final out = artUrl(messy, px: 100)!;
    expect(out, contains('QUDxxbtWMDew68xCjZPtfg==/'));
  });

  test('尺寸只落到几档，同屏请求能共用一份缓存', () {
    expect(artUrl(messy, px: 44)!.endsWith('param=120y120'), isTrue);
    expect(artUrl(messy, px: 132)!.endsWith('param=200y200'), isTrue);
    expect(artUrl(messy, px: 324)!.endsWith('param=400y400'), isTrue);
    expect(artUrl(messy, px: 900)!.endsWith('param=600y600'), isTrue);
  });

  test('改写是幂等的，取色和展示两处拿到的是同一个地址', () {
    final once = artUrl(messy, px: 300)!;
    expect(artUrl(once, px: 300), once);
  });

  test('非网易云的地址不动（酷我的 CDN 认自己的域名）', () {
    const kw = 'https://img4.kuwo.cn/star/albumcover/120/s3s94/93/2761694302.jpg';
    expect(artUrl(kw, px: 44), kw);
  });

  test('空地址返回 null，让调用方回落到音符图标', () {
    expect(artUrl(null), isNull);
    expect(artUrl('   '), isNull);
  });
}
