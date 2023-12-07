#ifdef __cplusplus
class CxxCountdown
{
public:
    CxxCountdown(bool printCount);
    void countdown(int x) const;
private:
    bool printCount;
};
#endif  // __cplusplus
